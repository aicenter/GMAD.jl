seed = 1
method = "leave-one-in"
contamination = 0.0

main_inpath = datadir("experiments/images_leave-one-in_backup/$(modelname)/$(dataset)")
main_savepath = datadir("experiments/images_leave-one-in/$(modelname)/$(dataset)")
mkpath(main_savepath)

# this loop unfortunately cannot be in a function, since loading of bson is only safe ot top level
for ac in 1:10
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
end
