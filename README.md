# IBM Concert 3.1.0 on EKS: L3 Demo Build

Rebuild of the August 2026 EKS install (`../EKS/IBM_Concert_Platform_3.0_EKS_Installation_Guide.md`) on **Concert v3.1.0**
(released 2026-10-01). It installs **Hub + Concert + Data Apps + Workflows**, with AI on. Secure Coder is not installed.
The demo script doesn't use Data Apps; it is included so the environment is complete.

Demo data comes from three real OWASP apps that run on the same cluster: **Juice Shop, WebGoat and WrongSecrets**.
The demo script is in [`Concert_3.1_L3_Demo_Script.md`](Concert_3.1_L3_Demo_Script.md).

## One command (from the Mac)
```bash
cp secrets.env.example secrets.env && chmod 600 secrets.env   # fill in the keys once
./run-all.sh                   # cluster -> install -> post-install -> demo data (~2 h)
./run-all.sh --from install    # re-run from a stage after fixing a failure
./scripts/99-teardown.sh       # delete everything afterwards
```
`run-all.sh` pauses once, after install, for you to generate a Concert API key in the UI (unless
`CONCERT_API_KEY` is already set). The installer runs **inside the cluster as a Job**, so CloudShell is not
needed, and closing the laptop doesn't stop the install; re-running re-attaches to the Job's logs.
The Workflows and GitHub UI steps in section 2 stay manual. The manual steps below still work if you want to run stages yourself.

## CI pipeline (GitHub Actions)
The same stages run from **Actions** in this repo, so no laptop needs to stay open. Every workflow is started manually (`workflow_dispatch`).

| Workflow | What it does | Time |
|---|---|---|
| **Install Concert on EKS** (`install.yml`) | 1. cluster + EFS → 2. installer Job in the cluster → 3. ingress, Keycloak SSO, watsonx, health check. Input `start_from` re-runs from a later stage | ~2 h |
| **Load demo data** (`demo-data.yml`) | Demo apps, Trivy/Semgrep scans, SBOMs, certificates, upload to Concert, cert-renewal RBAC | ~30 min |
| **Teardown EKS** (`teardown.yml`) | `99-teardown.sh` with the cluster name typed as confirmation | ~20 min |
| **Lint** (`lint.yml`) | `bash -n`, Python syntax and shellcheck on every push | 1 min |

**Repo secrets** (Settings → Secrets and variables → Actions):

| Secret | Notes |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (+ `AWS_SESSION_TOKEN` if temporary) | IAM identity allowed to create EKS, EC2, EFS and IAM roles |
| `IBM_ENTITLEMENT_KEY`, `WATSONX_API_KEY`, `WATSONX_API_PROJECT_ID`, `CONCERT_ADMIN_PASSWORD` | Same as `secrets.env` |
| `CONCERT_API_KEY` | Only for **Load demo data**. Generate it in the Concert UI after install |

**Repo variables** (optional):

| Variable | Default | Notes |
|---|---|---|
| `EXTRA_ADMIN_ARNS` | none | Space-separated IAM ARNs given cluster-admin. Put your own user here; otherwise only the pipeline's identity can use kubectl |
| `RUNNER_LABELS` | `"ubuntu-latest"` | JSON. For a self-hosted runner, e.g. `["self-hosted","linux","x64"]` |
| `WATSONX_API_URL` | `https://eu-gb.ml.cloud.ibm.com` | |
| `DEMO_ALLOWED_CIDR` | runner's IP | Who can reach the demo app LBs, e.g. `203.0.113.7/32` |
| `DEMO_GITHUB_USER` | `vivek99singh` | Owner of the juice-shop / WebGoat / wrongsecrets forks |

Flow: run **Install** → log in and generate the API key → save it as `CONCERT_API_KEY` → run **Load demo data** →
do the UI steps in section 2 → run **Teardown** when finished. The runner needs Linux x86_64 with bash, curl, python3 and docker
(GitHub's `ubuntu-latest` has these); aws, kubectl, helm, trivy and semgrep are installed if missing.

```
EKS-3.1/
├── .github/workflows/             # CI pipeline (above)
├── run-all.sh                     # Mac: runs every stage below in order, resumable (.run-state)
├── secrets.env.example            # copy to secrets.env (not shared)
├── params.ini                     # 3.1.0 params, filled in by 01-install-concert.sh
├── scripts/
│   ├── 00-create-cluster.sh       # Mac: IAM roles, EKS 1.36, add-ons, 2 x c5.4xlarge On-Demand
│   ├── 01-install-in-cluster.sh   # Mac: runs 01-install-concert.sh as a Job in the cluster
│   ├── 01-install-concert.sh      # Linux (Job or CloudShell): storage class, download, Workflows LB, params, setup
│   ├── 02-post-install.sh         # NGINX, Concert ingress, health checks, URLs
│   └── 99-teardown.sh             # ELBs -> node group -> cluster -> leftover EBS volumes
├── demo-data/
│   ├── demo-apps.yaml             # juice-shop / webgoat / wrongsecrets (LBs locked to your IP)
│   └── load-demo-data.sh          # Mac: deploy, scan, SBOMs, certs, compliance, upload
└── Concert_3.1_L3_Demo_Script.md
```

## What changed from the 3.0.0 guide

| 3.0.0 guide section | 3.1.0 |
|---|---|
| Package dirs `ibm-concert-k8s-workflows/…` | Now `concert/`, `concert-workflows/`, `dataapps/`. Workflows LB file: `concert-workflows/bin/aws-eks/service-cw-ext.yaml` (unchanged content) |
| §11 watsonx.ai: patch `app-cfg-cm` after install | **Not needed.** `ENABLE_AI=true`, `WATSONX_API_URL` and `WATSONX_API_PROJECT_ID` go in params.ini, and `WATSONX_API_KEY` is exported before setup |
| §13 `register-agents.sh` | 3.1.0 ITOM ships an agent-card registry **job** plus product agent cards. Check after install; use the old script only if agents are missing |
| `ENABLE_CROSS_PRODUCT_INTEGRATION` | Set to `true`. It was blank in the 3.0.0 `params.ini`, which is why ITOM/agents were missing |
| New params | `ENABLE_HPA` (left `false`) |
| New tools | `bin/uninstall-products-on-k8s`, `bin/set-byo-secret` |
| `setup` flags | Unchanged: `--license_acceptance --username --password --registry_password` |
| Registry | The 3.1.0 sample says `icr.io/cp`, but setup's own default is `cp.icr.io/cp`. We keep `cp.icr.io/cp` (worked in 3.0.0). If images fail to pull, try `icr.io/cp` |

Unchanged lessons from 3.0.0: run the installer from CloudShell, not macOS. Set a default storage class first.
Use NGINX buffers `"8 64k"`. Workflows needs its own LB.

## Order of operations

### 0. Cluster: follow sections 2–6 of the 3.0.0 guide, with these differences
- **Nodes:** 2 × Spot, 16 vCPU / 32 GB, 512 GB disk, all in us-east-1b (EBS volumes are zonal). August ran Concert + Data Apps + Workflows on 2 × c5.4xlarge.
- **Demo day:** use **On-Demand**, not Spot, for the node group. A Spot reclaim mid-demo takes Concert down for 15+ minutes.
- Keep the **EBS CSI driver** add-on and the IAM access entry for your CLI user.

### 1. Install (CloudShell)
Upload the `EKS-3.1` folder to CloudShell (Actions → Upload file, as a zip), then:
```bash
export IBM_ENTITLEMENT_KEY=...  WATSONX_API_KEY=...  WATSONX_API_PROJECT_ID=...  CONCERT_ADMIN_PASSWORD=...
cd EKS-3.1/scripts
nohup ./01-install-concert.sh > ~/concert-install.log 2>&1 &
tail -f ~/concert-install.log          # wait for "DEPLOYMENT SUCCESSFUL"
./02-post-install.sh                   # prints Concert + Workflows URLs
```

### 2. One-time UI configuration
1. **Workflows → Authentications → Create**: name `concert-self`, service **IBM Hub - Self**. Without this, discovery and AI workflows can't call Concert.
2. **Concert → Administration → Integrations → Connections → GitHub**: host `api.github.com` and a PAT with `repo` scope. This is used to open real tickets.
   Enable **Issues** on the `vivek99singh/juice-shop` fork, because forks have Issues off by default.
3. **Concert → profile → API key**: generate one and export it as `CONCERT_API_KEY` for the data loader.
4. Check that the watsonx chat ("Ask watsonx") answers. If it doesn't, fall back to §11 of the 3.0.0 guide.

### 3. Demo data (from your Mac)
```bash
colima start                                   # docker for the Concert toolkit
aws eks update-kubeconfig --name concert-demo --region us-east-1
export CONCERT_API_KEY=...
cd EKS-3.1/demo-data
./load-demo-data.sh all                        # deploy -> scan -> sbom -> certs -> upload
./load-demo-data.sh compliance                 # optional: EKS CIS benchmark
./load-demo-data.sh upload-compliance          # format accepted by 3.1 still to be verified
```
Allow about 15 minutes after upload for Concert to finish processing (Integrations → Ingestion jobs).
Then fill in the "Values to capture" table at the top of the demo script.

### 4. Teardown (in this order, or ELBs are orphaned)
```bash
kubectl delete namespace demo-apps                                   # 3 app ELBs
kubectl delete svc -n concert-workflows solis-gw-ext                 # Workflows ELB
helm uninstall concert-ingress-nginx -n concert-ingress-nginx        # Concert ELB
```
Then delete the node group and the cluster, check EC2 → Volumes for leftover EBS volumes, and remove the IAM roles. This is the same as §16 of the 3.0.0 guide.

## Open items to verify on the live system
| Item | Why |
|---|---|
| Resilience data path | The toolkit has no resilience upload type; IBM sources metrics from Instana/ITSM. We need to check the 3.1 API and Workflows integration packages for a way to feed NFR metrics (for example multi-zone %). See demo script §1 |
| `compliance-posture` format | The toolkit accepts the key, but it is not yet confirmed that a Trivy CIS JSON is the format 3.1 expects. Fallback: NIST 800-53 catalog + profile + assessment in the UI |
| Agent auto-registration | Confirm the agents are present. If not, adapt `../EKS/register-agents.sh`, which has a hard-coded secret, so read it from `access-keys-secret` |
| Home page dimension wheel | On OCP the 3.0 Home returned 401 without TurboLite. Check on 3.1 |
| ingress-nginx | The upstream project is in maintenance-only mode. It still works for this demo; the AWS Load Balancer Controller is the long-term option |
