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

modelname = "$(enc)_knn"


function sample_params()
	par_vec = (1:2:101,)
	argnames = (:k,)
	return (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end

function fit(data, parameters, aux_info)
	# construct model - constructor should only accept kwargs
	model = GenerativeAD.Models.knn_constructor(;v=:kappa, parameters...)

	# fit train data
	try
		global info, fit_t, _, _, _ = @timed fit!(model, data[1][1])
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
	function knn_predict(model, x, v::Symbol)
		try 
			return predict(model, x, v)
		catch e
			if isa(e, ArgumentError) # this happens in the case when k > number of points
				return NaN # or nothing?
			else
				rethrow(e)
			end
		end
	end
	parameters = merge(parameters, aux_info)
	training_info, [(x -> knn_predict(model, x, v), merge(parameters, (distance = v,))) for v in [:gamma, :kappa, :delta]]
end


####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# set a maximum for parameter sampling retries
if abspath(PROGRAM_FILE) == @__FILE__

	try_counter = 0
	max_tries = 10*max_seed
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
					training_info, results = fit(data, parameters, aux_info)
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
