using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON

s = ArgParseSettings()
@add_arg_table! s begin
	"max_seed"
		default = 1
		arg_type = Int
		help = "max_seed"
	"category"
		default = "wood"
		arg_type = String
		help = "dataset"
	"contamination"
		arg_type = Float64
		help = "contamination rate of training data"
		default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack category, max_seed, contamination = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################

modelname = "knn"

# sample parameters, should return a Dict of model kwargs 
"""
	sample_params()

Should return a named tuple that contains a sample of model parameters.
"""
function sample_params()
	par_vec = (1:2:101,)
	argnames = (:k,)
	return (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end
"""
	fit(data, parameters)

This is the most important function - returns `training_info` and a tuple or a vector of tuples `(score_fun, final_parameters)`.
`training_info` contains additional information on the training process that should be saved, the same for all anomaly score functions.
Each element of the return vector contains a specific anomaly score function - there can be multiple for each trained model.
Final parameters is a named tuple of names and parameter values that are used for creation of the savefile name.
"""
function fit(data, parameters)
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
	training_info, [(x -> knn_predict(model, x, v), merge(parameters, (distance = v,))) for v in [:gamma, :kappa, :delta]]
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# set a maximum for parameter sampling retries
try_counter = 0
max_tries = 10*max_seed
cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"
while try_counter < max_tries
	parameters = sample_params()

	for seed in 1:max_seed
		savepath = datadir("experiments/images_mvtec$(cont_string)/$(modelname)/$(category)/ac=1/seed=$(seed)")
		mkpath(savepath)

		# get data
		data = GenerativeAD.load_data("MVTec-AD", seed=seed, category=category, 
			contamination=contamination, img_size=64)
		data = GenerativeAD.Datasets.vectorize(data)

		# edit parameters
		edited_parameters = GenerativeAD.edit_params(data, parameters)
		
		@info "Trying to fit $modelname on $category with parameters $(edited_parameters)..."
		# check if a combination of parameters and seed alread exists
		if GenerativeAD.check_params(savepath, edited_parameters)
			# fit
			training_info, results = fit(data, edited_parameters)
			# here define what additional info should be saved together with parameters, scores, labels and predict times
			save_entries = merge(training_info, (modelname = modelname, seed = seed, 
				category = category, dataset = "MVTec-AD_$category",
				contamination=contamination))

			# now loop over all anomaly score funs
			for result in results
				GenerativeAD.experiment(result..., data, savepath; save_entries...)
			end
			global try_counter = max_tries + 1
		else
			@info "Model already present, trying new hyperparameters..."
			global try_counter += 1
		end
	end
end
(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
