using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
using Flux
using IPMeasures
using GenerativeModels
using Distributions
using PyCall
using OrderedCollections

s = ArgParseSettings()
@add_arg_table! s begin
   "max_seed"
        default = 1
        arg_type = Int
        help = "seed"
    "dataset"
        default = "iris"
        arg_type = String
        help = "dataset"
    "sampling"
		default = "random"
		arg_type = String 
		help = "sampling of hyperparameters - random/bayes"
    "contamination"
    	arg_type = Float64
    	help = "contamination rate of training data"
    	default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, max_seed, sampling, contamination = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################
modelname = "wae_full"
# sample parameters, should return a Dict of model kwargs 
"""
	sample_params()

Should return a named tuple that contains a sample of model parameters.
"""
function sample_params()
	par_vec = (2 .^(3:8), 2 .^(4:9), 10f0 .^(-4:-3), 2 .^ (5:7), ["relu", "swish", "tanh"], 3:4, 1:Int(1e8),
		["imq", "gauss", "rq"], 10f0 .^ (-3:0), 10f0 .^(-1:0), 2 .^ (1:6), ["normal", "vamp"])
	argnames = (:zdim, :hdim, :lr, :batchsize, :activation, :nlayers, :init_seed, :kernel, :sigma, :lambda,
		:k, :prior)
	parameters = (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
	# ensure that zdim < hdim
	while parameters.zdim >= parameters.hdim
		parameters = merge(parameters, (zdim = sample(par_vec[1])[1],))
	end
	return parameters
end
function create_space()
    pyReal = pyimport("skopt.space")["Real"]
    pyInt = pyimport("skopt.space")["Integer"]
    pyCat = pyimport("skopt.space")["Categorical"]
    
    (;
    zdim        = pyInt(1, 8,                                   name="log2_zdim"),
    hdim        = pyInt(4, 9,                                   name="log2_hdim"),
    lr          = pyReal(1f-4, 1f-3, prior="log-uniform",       name="lr"),
    batchsize   = pyInt(5, 7,                                   name="log2_batchsize"),
    activation  = pyCat(categories=["relu", "swish", "tanh"],   name="activation"),
    nlayers     = pyInt(3, 4,                                   name="nlayers"),
    kernel      = pyCat(categories=["imq", "gauss", "rq"],      name="kernel"),
    sigma       = pyReal(1f-3, 1f0, prior="log-uniform",        name="sigma"),
    lambda      = pyReal(1f-1, 1f0, prior="log-uniform",        name="lambda"),
    k           = pyInt(1, 6,                                   name="log2_k"),
    prior       = pyCat(categories=["normal", "vamp"],          name="prior")
    )
end

sample_reconstruction_batched(m,x,L,batchsize) = 
	vcat(map(y-> Base.invokelatest(GenerativeAD.Models.reconstruction_score, m, y, L), Flux.Data.DataLoader(x, batchsize=batchsize))...)

"""
	fit(data, parameters)

This is the most important function - returns `training_info` and a tuple or a vector of tuples `(score_fun, final_parameters)`.
`training_info` contains additional information on the training process that should be saved, the same for all anomaly score functions.
Each element of the return vector contains a specific anomaly score function - there can be multiple for each trained model.
Final parameters is a named tuple of names and parameter values that are used for creation of the savefile name.
"""
function fit(data, parameters)
	# first construct the VAMP pseudoinput array
	X = data[1][1]
	pseudoinput_mean = mean(X, dims=ndims(X))

	# construct model - constructor should only accept kwargs
	model = GenerativeAD.Models.vae_constructor(;idim=size(data[1][1],1), 
		var="diag", pseudoinput_mean=pseudoinput_mean, parameters...)

	# construct loss function
	if parameters.kernel == "imq"
		k = IMQKernel(parameters.sigma)
	elseif parameters.kernel == "gauss"
		k = GaussianKernel(parameters.sigma)
	elseif parameters.kernel == "rq"
		k = RQKernel(parameters.sigma)
	else
		error("given kernel not known")
	end
	loss(m::GenerativeModels.VAE,x) = parameters.lambda*mmd_mean(m, x, k) .- mean(logpdf(m.decoder, x, rand(m.encoder, x)))
	loss(m::GenerativeModels.VAE, x, batchsize::Int) = 
		mean(map(y->loss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))

	# fit train data
	try
		global info, fit_t, _, _, _ = @timed fit!(model, data, loss;
			max_train_time= 82800/max_seed/2, 
			patience=200, check_interval=10, parameters...)
	catch e
		# return an empty array if fit fails so nothing is computed
		@info "Failed training due to \n$e"
		return (fit_t = NaN, history=nothing, npars=nothing, model=nothing), [] 
	end

	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = fit_t,
		history = info.history,
		npars = info.npars,
		model = info.model
		)

	# now return the different scoring functions
	L=100
	training_info, [
		(x -> GenerativeAD.Models.reconstruction_score(info.model, x), merge(parameters, (score = "reconstruction",))),
		(x -> GenerativeAD.Models.reconstruction_score_mean(info.model, x), merge(parameters, (score = "reconstruction-mean",))),
		(x -> sample_reconstruction_batched(info.model, x, L, 512), merge(parameters, (score = "reconstruction-sampled", L=L)))
		]		
end
function GenerativeAD.edit_params(data, parameters)
	idim = size(data[1][1],1)
	# put the largest possible zdim where zdim < idim, the model tends to converge poorly if the latent dim is larger than idim
	if parameters.zdim >= idim
		zdims = 2 .^(1:8)
		zdim_new = zdims[zdims .< idim][end]
		parameters = merge(parameters, (zdim=zdim_new,))
	end
	parameters
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# only execute this if run directly - so it can be included in other files
if abspath(PROGRAM_FILE) == @__FILE__
	# set a maximum for parameter sampling retries
	try_counter = 0
	max_tries = 10*max_seed
	cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"
	sampling_string = sampling == "bayes" ? "_bayes" : "" 
	prefix = "experiments$(sampling_string)/tabular$(cont_string)"
	dataset_folder = datadir("$(prefix)/$(modelname)/$(dataset)")
	while try_counter < max_tries
		if sampling == "bayes"
			parameters = GenerativeAD.bayes_params(
									create_space(), 
									dataset_folder,
									sample_params; add_model_seed=true)
		else
			parameters = sample_params()
		end

	    for seed in 1:max_seed
			savepath = joinpath(dataset_folder, "seed=$(seed)")
			mkpath(savepath)

			# get data
			data = GenerativeAD.load_data(dataset, seed=seed, contamination=contamination)
					
			# edit parameters
			edited_parameters = sampling == "bayes" ? parameters : GenerativeAD.edit_params(data, parameters)
			
			@info "Trying to fit $modelname on $dataset with parameters $(edited_parameters)..."
			@info "Train/validation/test splits: $(size(data[1][1], 2)) | $(size(data[2][1], 2)) | $(size(data[3][1], 2))"
			@info "Number of features: $(size(data[1][1], 1))"

			# check if a combination of parameters and seed alread exists
			if GenerativeAD.check_params(savepath, edited_parameters)
				# fit
				training_info, results = fit(data, edited_parameters)

				# save the model separately			
				if training_info.model !== nothing
					tagsave(joinpath(savepath, savename("model", edited_parameters, "bson", digits=5)), 
						Dict("model"=>training_info.model,
							"fit_t"=>training_info.fit_t,
							"history"=>training_info.history,
							"parameters"=>edited_parameters
							), safe = true)
					training_info = merge(training_info, (model = nothing,))
				end

				# here define what additional info should be saved together with parameters, scores, labels and predict times
				save_entries = merge(training_info, (modelname = modelname, seed = seed, dataset = dataset, contamination = contamination))

				# now loop over all anomaly score funs
				all_scores = [GenerativeAD.experiment(result..., data, savepath; save_entries...) for result in results]
				if sampling == "bayes" && length(all_scores) > 0
					@info("Updating cache with $(length(all_scores)) results.")
					GenerativeAD.update_bayes_cache(dataset_folder, 
							all_scores; ignore=Set([:init_seed, :L, :score]))
				end
				global try_counter = max_tries + 1
			else
				@info "Model already present, trying new hyperparameters..."
				global try_counter += 1
			end
		end
	end
	(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
end
