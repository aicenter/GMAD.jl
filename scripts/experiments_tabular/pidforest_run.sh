#!/bin/bash
# SBATCH --time=24:00:00
# SBATCH --nodes=1 --ntasks-per-node=1 --cpus-per-task=1
# SBATCH --mem=20G
# SBATCH --error=/home/francja5/logs/pidforest.%j.err
# SBATCH --out=/home/francja5/logs/pidforest.%j.out

MAX_SEED=$1
DATASET=$2

module load Julia/1.4.1-linux-x86_64
module load Python/3.8.2-GCCcore-9.3.0

# load virtualenv
source /home/francja5/pidforest-env/bin/activate
export PYTHON="/home/francja5/pidforest-env/bin/python"

# PyCall needs to be rebuilt if environment changed
julia --project -e 'using Pkg; Pkg.build("PyCall"); @info("SETUP DONE")'

for ((SEED=1; SEED<=$MAX_SEED; SEED++))
do	
	julia --project ./pidforest.jl $SEED $DATASET
done