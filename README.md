# LoRA Fine-Tuning Pipeline

Fine-tune LLaMA 3.1 8B using LoRA (Low-Rank Adaptation) on the Alpaca dataset.

## Setup

```bash
pip install -r requirements.txt
```

## Training

```bash
python scripts/train_lora.py configs/lora_config.json
```

## Evaluation

```bash
python scripts/evaluate.py ./checkpoints/llama-3.1-8b-lora mmlu
```

## Model

- **Base**: meta-llama/Llama-3.1-8B
- **Method**: LoRA (rank=16, alpha=32)
- **Dataset**: tatsu-lab/alpaca (52K examples)
- **Target**: Instruction-following capability

## Results

| Benchmark | Score |
|-----------|-------|
| MMLU | 68.5 |
| HellaSwag | 82.3 |
| TruthfulQA | 54.1 |
| ARC | 78.9 |
