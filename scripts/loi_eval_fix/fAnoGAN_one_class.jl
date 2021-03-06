include("utils.jl") # contains most dependencies and the saving function
using PDMats
using FillArrays

s = ArgParseSettings()
@add_arg_table! s begin
	"dataset"
		default = "MNIST"
		arg_type = String
		help = "dataset"
	"class"
		default = 1
		arg_type = Int
		help = "dataset"
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, class = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################

modelname = "fAnoGAN"

"""
This returns encodings, parameters and scoring functions in order to reconstruct the experiment. 
This is a slightly updated version of the original run script.
"""
function evaluate(model_data, data, parameters)
	# load the model file, extract params and model
	model = model_data["model"] |> gpu
	
	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = get(model_data, "fit_t", nothing),
		history = get(model_data, "history", nothing),
		npars = get(model_data, "npars", nothing),
		model = model |> cpu
	)

	# now return the different scoring functions
	training_info, [(x -> GenerativeAD.Models.anomaly_score_gpu(model, x), parameters)]
end

##################
# this is common #
##################
seed = 1
method = "leave-one-in"
contamination = 0.0
ac = class

main_inpath = datadir("experiments/images_leave-one-in_backup/$(modelname)/$(dataset)")
main_savepath = datadir("experiments/images_leave-one-in/$(modelname)/$(dataset)")
mkpath(main_savepath)

# this loop unfortunately cannot be in a function, since loading of bson is only safe ot top level
data = GenerativeAD.load_data(dataset, seed=seed, anomaly_class_ind=ac, method=method, 
	contamination=contamination)

inpath = joinpath(main_inpath, "ac=$ac/seed=$seed")
savepath = joinpath(main_savepath, "ac=$ac/seed=$seed")
mkpath(savepath)
fs = readdir(inpath, join=true)
sfs = filter(x->!(occursin("model", x)), fs)
mfs = filter(x->(occursin("model", x)), fs)

@info "Loaded $(length(mfs)) modelfiles in $inpath, processing..."
for mf in mfs
	# load the bson file on top level, otherwise we get world age problems
	model_data = load(mf)
	if haskey(model_data, "parameters")
		parameters = model_data["parameters"]
	else # this is in case parameters are not saved in the model file
		init_seed = DrWatson.parse_savename(mf)[2]["init_seed"]
		sf = sfs[map(x->DrWatson.parse_savename(x)[2]["init_seed"], sfs) .== init_seed][1]
		score_data = load(sf)
		parameters = score_data[:parameters]
	end
	try
		training_info, results = evaluate(model_data, data, parameters) # this produces parameters, encodings, score funs
		save_results(parameters, training_info, results, savepath, data, 
			ac, modelname, seed, dataset, contamination) # this computes and saves score and model files
	catch e
		if isa(e, LoadError)
			@warn "$mf failed during result evaluation due to $e"
		else
			rethrow(e)
		end
	end
end
