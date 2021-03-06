# this contains stuff that is common for VAE, WAE and AAE models
"""
	AEModel

A Union of VAE and AAE types.
"""
const AEModel = Union{VAE, AAE}

# these functions need to be overloaded for convolutional models
function ConditionalDists.condition(p::ConditionalMvNormal, z::AbstractArray{T,4}) where T
	(μ,σ) = ConditionalDists.mean_var(p.mapping(z))
	if size(σ,1) == 1
		σ = dropdims(σ, dims=1)
	end
	ConditionalDists.BatchMvNormal(μ,σ)
end
Distributions.logpdf(d::ConditionalDists.BMN, x::AbstractArray{T,4}) where T<:Real =
	Distributions.logpdf(d, reshape(x,:,size(x,4)))
Distributions.mean(p::ConditionalMvNormal, z::AbstractArray{T,4}) where T<:Real = mean(condition(p,z))
Distributions.var(p::ConditionalMvNormal, z::AbstractArray{T,4}) where T<:Real = var(condition(p,z))
Distributions.rand(p::ConditionalMvNormal, z::AbstractArray{T,4}) where T<:Real = rand(condition(p,z))
Distributions.logpdf(p::ConditionalMvNormal, x::AbstractArray{T,4}, z::AbstractArray{T,2}) where T<:Real = 
	logpdf(condition(p,z), x)

# this has to be overloaded for convolutional models with conv var
struct BatchTensorMvNormal{Tm<:AbstractArray,Tσ<:AbstractVector} <: ContinuousMatrixDistribution
    μ::Tm
    σ::Tσ
end
ConditionalDists.BatchMvNormal(μ::AbstractArray{T}, σ::AbstractVector{T}) where T<:Real = BatchTensorMvNormal(μ,σ)
Base.eltype(d::BatchTensorMvNormal) = eltype(d.μ)
Distributions.params(d::BatchTensorMvNormal) = (d.μ, d.σ)
Distributions.mean(d::BatchTensorMvNormal) = d.μ
Distributions.var(d::BatchTensorMvNormal) = 
	reshape(ConditionalDists.fillsimilar(d.σ,prod(size(d.μ)[1:3]),1) .* 
		reshape(d.σ .^2,1,:), size(d.μ))
function Distributions.rand(d::BatchTensorMvNormal)
    μ, σ = d.μ, d.σ
    r = DistributionsAD.adapt_randn(Random.GLOBAL_RNG, μ, size(μ)...)
    μ .+ σ .* r
end
function Distributions.logpdf(d::BatchTensorMvNormal, x::AbstractArray{T}) where T<:Real
    n = prod(size(d.μ)[1:3])
    μ = mean(d)
    σ2 = var(d)
    -vec(sum(((x - μ).^2) ./ σ2 .+ log.(σ2), dims=(1,2,3)) .+ n*log(T(2π))) ./ 2
end

"""
	reconstruct(model::AEModel, x)

Data reconstruction.
"""
reconstruct(model::AEModel, x) = mean(model.decoder, rand(model.encoder, x))
reconstruct(model::AEModel, x::AbstractArray{T,4}) where T = 
	reshape(mean(model.decoder, rand(model.encoder, x)), size(x)...)

"""
	generate(model::AEModel, N::Int[, outdim])

Data generation. Support output dimension if the output needs to be reshaped, e.g. in convnets.
"""
generate(model::AEModel, N::Int) = mean(model.decoder, rand(model.prior, N))
generate(model::AEModel, N::Int, outdim) = reshape(generate(model, N), outdim..., :)

"""
	encode_mean(model::AEModel, x)

Produce data encodings.
"""
encode_mean(model::AEModel, x) = mean(model.encoder, x)
"""
	encode_mean_gpu(model::AEModel, x[, batchsize])

Produce data encodings. Works only on 4D tensors.
"""
encode_mean_gpu(model, x::AbstractArray{T,4}) where T = encode_mean(model, gpu(Array(x)))
function encode_mean_gpu(model, x::AbstractArray{T,4}, batchsize::Int) where T
	# this has to be done in a loop since doing cat(map()...) fails if there are too many arguments
	dl = Flux.Data.DataLoader(x, batchsize=batchsize)
	z = encode_mean_gpu(model, iterate(dl,1)[1])
	N = size(x, ndims(x))
	encodings = gpu(zeros(eltype(z), size(z,1), N))
	for (i,batch) in enumerate(dl)
		encodings[:,1+(i-1)*batchsize:min(i*batchsize,N)] .= encode_mean_gpu(model, batch)
	end
	encodings
end

"""
	reconstruction_score(model::AEModel, x[, L=1])

Anomaly score based on the reconstruction probability of the data.
"""
function reconstruction_score(model::AEModel, x) 
	p = condition(model.decoder, rand(model.encoder, x))
	-logpdf(p, x)
end
reconstruction_score(model::AEModel, x, L::Int) = 
	mean([reconstruction_score(model, x) for _ in 1:L])

"""
	reconstruction_score_mean(model::AEModel, x)

Anomaly score based on the reconstruction probability of the data. Uses mean of encoding.
"""
function reconstruction_score_mean(model::AEModel, x) 
	p = condition(model.decoder, mean(model.encoder, x))
	-logpdf(p, x)
end
"""
	latent_score(model::AEModel, x[, L=1]) 

Anomaly score based on the similarity of the encoded data and the prior.
"""
function latent_score(model::AEModel, x) 
	z = rand(model.encoder, x)
	-logpdf(model.prior, z)
end
latent_score(model::AEModel, x, L::Int) = 
	mean([latent_score(model, x) for _ in 1:L])

"""
	latent_score_mean(model::AEModel, x) 

Anomaly score based on the similarity of the encoded data and the prior. Uses mean of encoding.
"""
function latent_score_mean(model::AEModel, x) 
	z = mean(model.encoder, x)
	-logpdf(model.prior, z)
end

"""
	aae_score(model::AAE, x, alpha::Real)

A combination of reconstruction and discriminator score.
"""
aae_score(model::AAE, x, alpha::Real) = 
	alpha*GenerativeAD.Models.reconstruction_score_mean(model, x) .+ 
	(1-alpha)*vec(model.discriminator(mean(model.encoder, x)))

# JacoDeco score
# see https://arxiv.org/abs/1905.11890
"""
	jacobian(f, x)

Jacobian of f given due to x.
"""
function jacobian(f, x)
	y = f(x)
	n = length(y)
	m = length(x)
	T = eltype(y)
	j = Array{T, 2}(undef, n, m)
	for i in 1:n
		j[i, :] .= gradient(x -> f(x)[i], x)[1]
	end
	return j
end

"""
	lJacoD(m,x)

Jacobian decomposition JJ(m,x).
"""
function lJacoD(m,x)
	JJ = zeros(eltype(x),size(x,ndims(x)));
	zg = mean(m.encoder,x);
	for i=1:size(x,ndims(x))
		jj,J = jacobian(y->mean(m.decoder,reshape(y,:,1))[:],zg[:,i]);
		(U,S,V) = svd(J);
		JJ[i]= sum(2*log.(S));
	end
	JJ
end

"""
	lpx(m,x)

p(x|g(x))
"""
lpx(m,x) = logpdf(m.decoder,x,mean(m.encoder,x))

"""
	lpz(m,x)

p(z|e(x))
"""
lpz(m,x) = logpdf(m.prior,mean(m.encoder,x)) # 

"""
	lp_orthD(m,x)

JacoDeco score: p(x|g(x)) + p(z|e(x)) - JJ(m,x)
"""
jacodeco(m,x) = (lpx(m,x) .+ lpz(m,x) .- lJacoD(m,x));
