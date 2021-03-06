using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
# because of vae and 2stage
using DataFrames
using CSV
using ValueHistories
using Flux
using ConditionalDists
using GenerativeModels
import GenerativeModels: VAE
using Distributions
using DistributionsAD

s = ArgParseSettings()
@add_arg_table! s begin
	"max_seed"
		default = 1
		arg_type = Int
		help = "max_seed"
	"category"
		default = "wood"
		arg_type = String
		help = "category"
	"tab_name"
		default = "vae_LOSS_images_mvtec"
		arg_type = String
		help = "name of tab -> example: vae_LOSS_images, wae-vamp_AUC_images"
	"mi_only"
		arg_type = Int
		default = -1
		help = "index of model in range 1 to 10 or -1 for all models"
    "contamination"
    	arg_type = Float64
    	help = "contamination rate of training data"
    	default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack category, max_seed, tab_name, mi_only, contamination = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################

sp = split(tab_name, "_")
enc = sp[1]
criterion = lowercase(sp[2])

modelname = "$(enc)_ocsvm"

function sample_params()
	par_vec = (round.([10^x for x in -4:0.1:2], digits=5),["poly", "rbf", "sigmoid"],[0.01,0.5,0.99])
	argnames = (:gamma,:kernel,:nu)
	return (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end

function joint_fit(models, data_splits)
	info = []
	for (model, data) in zip(models, data_splits)
		push!(info, fit!(model, data))
	end
	return info
end

function joint_prediction(models, data)
	joint_pred = Array{Float32}(undef, length(models), size(data,2))
	for (i,model) in enumerate(models)
		joint_pred[i,:] = predict(model, data)
	end
	return vec(mean(joint_pred, dims=1))
end

function StatsBase.fit(data, parameters, n_models, aux_info)
	# construct model - constructor should only accept kwargs
	models = [GenerativeAD.Models.OCSVM(;parameters...) for _ = 1:n_models]
	
	# sumbsample and fit train data
	tr_data = data[1][1]
	M,N = size(tr_data)
	split_size = floor(N/n_models)
	data_splits = [tr_data[:,Int(split_size*i+1):Int(split_size*(i+1))] for i = 0:n_models-1]

	try
		global info, fit_t, _, _, _ = @timed joint_fit(models, data_splits)
 	catch e
		# return an empty array if fit fails so nothing is computed
		return (fit_t = NaN,), [] 
	end

	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = fit_t,
		model = nothing
		)

	# now return the different scoring functions
	training_info, [(x->joint_prediction(models, x),  merge(parameters, aux_info))]
end


####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# set a maximum for parameter sampling retries
if abspath(PROGRAM_FILE) == @__FILE__
	try_counter = 0
	max_tries = 1
	cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"
	while try_counter < max_tries
		parameters = sample_params()

		for seed in 1:max_seed
			savepath = datadir("experiments/images_mvtec$cont_string/$(modelname)/$(category)/ac=1/seed=$(seed)")
			mkpath(savepath)

			mi_indexes = (mi_only == -1) ? [1:10...] : [mi_only]

			for mi = mi_indexes

				aux_info = (model_index=mi, criterion=criterion)
				data = GenerativeAD.load_data("MVTec-AD", seed=seed, category=category, 
					contamination=contamination, img_size=128)
				data, encoding_name, encoder_params = GenerativeAD.Models.load_encoding(tab_name, data, 1, dataset=category, seed=seed, model_index=mi)
				
				@info "Trying to fit $modelname on $category with parameters $(parameters)..."
				@info "Train/validation/test splits: $(size(data[1][1])) | $(size(data[2][1])) | $(size(data[3][1]))"
				@info "Number of features: $(size(data[1][1]))"
				# here, check if a model with the same parameters was already tested
				@info "Trying to fit $modelname on $category with parameters $(parameters)..."
				if GenerativeAD.check_params(savepath, merge(parameters, aux_info))
					training_info, results = fit(data, parameters, 10, aux_info)
					if training_info.model !== nothing
						tagsave(joinpath(savepath, savename("model", parameters, "bson", digits=5)), 
							Dict("model"=>training_info.model), 
							safe = true)
						training_info = merge(training_info, (model = nothing,))
					end
					save_entries = merge(training_info, (modelname = modelname, seed = seed,
						category = category,
						contamination=contamination))
					# now loop over all anomaly score funs
					for result in results
						GenerativeAD.experiment(result..., data, savepath; save_entries...)
					end
					global try_counter = max_tries + 1
				else
					@info "Model already present, sampling new hyperparameters..."
					global try_counter += 1
				end
			end
		end
	end
	(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
end
