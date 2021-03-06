using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
using PyCall
using StatsBase: fit!, predict, sample
using OrderedCollections
using BSON

s = ArgParseSettings()
@add_arg_table! s begin
	"max_seed"
		default = 1
		arg_type = Int
		help = "maximum number of seeds to run through"
	"dataset"
		default = "iris"
		arg_type = String
		help = "dataset"
	"sampling"
		default = "random"
		arg_type = String
		help = "sampling of hyperparameters"
	"contamination"
		arg_type = Float64
		help = "contamination rate of training data"
		default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, max_seed, sampling, contamination = parsed_args

modelname = "MAF"

function sample_params()
	parameter_rng = (
		nflows 		= 2 .^ (1:3),
		hdim 		= 2 .^(4:10),
		nlayers 	= 2:3,
		ordering 	= ["natural", "random"],
		lr 			= [1f-4],
		batchsize 	= 2 .^ (5:7),
		act_loc		= ["relu", "tanh"],
		act_scl		= ["relu", "tanh"],
		bn 			= [true, false],
		wreg 		= [0.0f0, 1f-5, 1f-6],
		init_I 		= [true, false],
		init_seed 	= 1:Int(1e8)
	)
	
	return (;zip(keys(parameters_rng), map(x->sample(x, 1)[1], parameters_rng))...)
end

function create_space()
	pyReal = pyimport("skopt.space")["Real"]
	pyInt = pyimport("skopt.space")["Integer"]
	pyCat = pyimport("skopt.space")["Categorical"]
	
	(;
		nflows 		= pyInt(1, 3, 								name="log2_nflows"),
		hdim 		= pyInt(4, 10, 								name="log2_hdim"),
		nlayers 	= pyInt(2, 3, 								name="nlayers"),
		ordering	= pyCat(categories=["natural", "random"], 	name="ordering"),
		lr 			= pyReal(1f-5, 1f-3, prior="log-uniform", 	name="lr"),
		batchsize 	= pyInt(5, 7, 								name="log2_batchsize"),
		act_loc		= pyCat(categories=["relu", "tanh"], 		name="act_loc"),
		act_scl		= pyCat(categories=["relu", "tanh"], 		name="act_scl"),
		bn 			= pyCat(categories=[true, false], 			name="bn"),
		wreg 		= pyReal(1f-7, 1f-3, prior="log-uniform", 	name="wreg"), # cannot turn it off
		init_I 		= pyCat(categories=[true, false], 			name="init_I")
	)
end

function fit(data, parameters)
	model = GenerativeAD.Models.MAF(;idim=size(data[1][1], 1), parameters...)

	try
		global info, fit_t, _, _, _ = @timed fit!(model, data; max_train_time=82800/max_seed, 
						patience=200, check_interval=10, parameters...)
	catch e
		@info "Failed training due to \n$e"
		return (fit_t = NaN, history=nothing, npars=nothing, model=nothing), []
	end

	training_info = (
		fit_t = fit_t,
		history = info.history,
		niter = info.niter,
		npars = info.npars,
		model = info.model
		)

	training_info, [(x -> predict(info.model, x), parameters)]
end


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
		edited_parameters = sampling == "bayes" ? parameters : GenerativeAD.edit_params(data, parameters)

		if GenerativeAD.check_params(savepath, edited_parameters)
			@info "Started training $(modelname)$(edited_parameters) on $(dataset):$(seed)"
			@info "Train/valdiation/test splits: $(size(data[1][1], 2)) | $(size(data[2][1], 2)) | $(size(data[2][1], 2))"
			@info "Number of features: $(size(data[1][1], 1))"
			
			training_info, results = fit(data, edited_parameters)

			if training_info.model !== nothing
				tagsave(joinpath(savepath, savename("model", edited_parameters, "bson", digits=5)), 
						Dict("model"=>training_info.model,
							"fit_t"=>training_info.fit_t,
							"history"=>training_info.history,
							"parameters"=>edited_parameters
							), safe = true)
				training_info = merge(training_info, (model = nothing,))
			end
			save_entries = merge(training_info, (modelname = modelname, seed = seed, dataset = dataset, contamination = contamination))

			all_scores = [GenerativeAD.experiment(result..., data, savepath; save_entries...) for result in results]
			if sampling == "bayes" && length(all_scores) > 0
				@info("Updating cache with $(length(all_scores)) results.")
				GenerativeAD.update_bayes_cache(dataset_folder, 
						all_scores; ignore=Set([:init_seed]))
			end
			global try_counter = max_tries + 1
		else
			@info "Model already present, trying new hyperparameters..."
			global try_counter += 1
		end
	end
end
(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
