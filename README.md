# Releasing a hotel cancellation model from a pipeline

A model change goes through a pull request, a gate, a registry version, an approval and an endpoint update, all from code.

| Path | What it is |
|---|---|
| `candidate/model.tar.gz` | The model a pull request changes. Starts as the baseline |
| `models/baseline`, `weighted`, `retrained` | Three trained models to copy into `candidate/` |
| `data/live.csv`, `live_labels.csv` | 1,000 bookings and how they really ended. The gate and the live check use them |
| `release/gate.py` | Scores the candidate against the model on main |
| `release/register.sh` | Uploads the file to S3 and registers a new version, Pending |
| `release/deploy.sh` | Approves a version, updates the endpoint, sets the stage. Also the rollback |
| `release/check_live.sh` | Sends the 1,000 bookings to the endpoint and counts |
| `infra/up.sh`, `down.sh` | The roles, OIDC provider and bucket in AWS, and their removal |
| `.github/workflows/release.yml`, `rollback.yml` | The pipeline |

Models, data and container come from the Hotel booking demand datasets (Antonio, de Almeida, Nunes, Data in Brief 22,
2019, CC BY 4.0) and the Model Registry class.
