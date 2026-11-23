# Releasing a hotel cancellation model from a pipeline

A model change goes through a pull request, a gate, a registry version, an approval and an endpoint update, all from code. Every AWS step is Python with boto3.

| Path | What it is |
|---|---|
| `candidate/model.tar.gz` | The model a pull request changes. Starts as the baseline |
| `models/baseline`, `weighted`, `retrained` | Three trained models to copy into `candidate/` |
| `data/live.csv`, `live_labels.csv` | 1,000 bookings and how they really ended. The gate and the live check use them |
| `release/gate.py` | Scores the candidate against the model on main |
| `release/config.py` | The names and the boto3 clients every script shares |
| `release/register.py` | Uploads the file to S3 and registers a new version, Pending |
| `release/deploy.py` | Approves a version, releases it blue/green with a canary two alarms watch, sets the stage. Also the rollback |
| `release/check_live.py` | Sends the 1,000 bookings to the endpoint and counts |
| `release/watch.py` | Calls the endpoint every 5 seconds during a release and says which model answered |
| `infra/up.py`, `down.py` | The endpoint's role, the alarms, the bucket and the GitHub Actions IAM user with its access key, and their removal |
| `infra/protect.sh` | The GitHub ruleset that makes the gate required |
| `requirements.txt` | boto3, the AWS SDK for Python, which every AWS step uses |
| `.github/workflows/release.yml`, `rollback.yml` | The pipeline |

Models, data and container come from the Hotel booking demand datasets (Antonio, de Almeida, Nunes, Data in Brief 22,
2019, CC BY 4.0) and the Model Registry class.
