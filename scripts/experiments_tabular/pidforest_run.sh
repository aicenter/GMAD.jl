#!/bin/bash
#SBATCH --time=24:00:00
#SBATCH --nodes=1 --ntasks-per-node=4 --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --qos==collaborator

MAX_SEED=$1
DATASET=$2
HP_SAMPLING=$3
CONTAMINATION=$4

module load Julia/1.5.3-linux-x86_64
module load Python/3.8.2-GCCcore-9.3.0

# load virtualenv containing skopt+sklearn+pidforest
source ${HOME}/sklearn-env/bin/activate
export PYTHON="${HOME}/sklearn-env/bin/python"

# PyCall needs to be rebuilt if environment changed
julia --project -e 'using Pkg; Pkg.build("PyCall"); @info("SETUP DONE")'

julia --project -e 'using Pkg; Pkg.instantiate();'

julia --project ./pidforest.jl $MAX_SEED $DATASET $HP_SAMPLING $CONTAMINATION
