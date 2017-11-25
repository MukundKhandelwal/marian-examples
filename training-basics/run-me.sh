#!/bin/bash -v

MARIAN=../..

# set chosen gpus
GPUS=0
if [ $# -ne 0 ]
then
    GPUS=$@
fi
echo Using GPUs: $GPUS

if [ ! -e $MARIAN/build/marian ]
then
    echo "marian is not installed in $MARIAN/build, you need to compile the toolkit first"
    exit 1
fi

if [ ! -e ../tools/moses-scripts ] || [ ! -e ../tools/subword-nmt ]
then
    echo "missing tools in ../tools, you need to download them first"
    exit 1
fi

if [ ! -e "data/corpus.en" ]
then
    ./scripts/download-files.sh
fi

mkdir -p model

# preprocess data
if [ ! -e "data/corpus.bpe.en" ]
then
    ./scripts/preprocess-data.sh
fi

# train model
if [ ! -e "model/model.npz" ]
then
    $MARIAN/build/marian \
        --devices $GPUS \
        --type amun \
        --model model/model.npz \
        --train-sets data/corpus.bpe.ro data/corpus.bpe.en \
        --vocabs model/vocab.ro.yml model/vocab.en.yml \
        --dim-vocabs 66000 50000 \
        --mini-batch-fit -w 3000 \
        --layer-normalization --dropout-rnn 0.2 --dropout-src 0.1 --dropout-trg 0.1 \
        --early-stopping 5 \
        --valid-freq 10000 --save-freq 10000 --disp-freq 1000 \
        --valid-metrics cross-entropy translation \
        --valid-sets data/newsdev2016.bpe.ro data/newsdev2016.bpe.en \
        --valid-script-path ./scripts/validate.sh \
        --log model/train.log --valid-log model/valid.log \
        --seed 1111 --exponential-smoothing
fi

# collect 4 best models on dev set
MODELS=`cat model/valid.log | grep translation | sort -rg -k8,8 -t' ' | cut -f4 -d' ' | head -n4 | xargs -I {} echo model/model.iter{}.npz | xargs`

# average 4 best models into single model
./scripts/average.py -m $MODELS -o model/model.avg.npz

# translate dev set
cat data/newsdev2016.bpe.ro \
    | $MARIAN/build/marian-decoder -c model/model.npz.decoder.yml -m model/model.avg.npz -d $GPUS -b 12 -n \
    | sed 's/\@\@ //g' \
    | ../tools/moses-scripts/scripts/recaser/detruecase.perl \
    | ../tools/moses-scripts/scripts/tokenizer/detokenizer.perl -l ro \
    > data/newsdev2016.ro.output

# translate test set
cat data/newstest2016.bpe.ro \
    | $MARIAN/build/marian-decoder -c model/model.npz.decoder.yml -m model/model.avg.npz -d $GPUS -b 12 -n \
    | sed 's/\@\@ //g' \
    | ../tools/moses-scripts/scripts/recaser/detruecase.perl \
    | ../tools/moses-scripts/scripts/tokenizer/detokenizer.perl -l ro \
    > data/newstest2016.ro.output

# calculate bleu scores on dev and test set
../tools/moses-scripts/scripts/generic/multi-bleu-detok.perl data/newsdev2016.en < data/newsdev2016.ro.output
../tools/moses-scripts/scripts/generic/multi-bleu-detok.perl data/newstest2016.en < data/newstest2016.ro.output
