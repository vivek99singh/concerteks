"""Writes ConcertDef 1.0.2 deploy SBOMs for the demo apps from the live cluster (usage: make-deploy-sboms.py <workdir>)."""
import datetime, json, subprocess, sys

WORK = sys.argv[1]
APPS = {
    "juice-shop":   ("Juice Shop",   "bkimminich/juice-shop",        "latest",          ["/", "/api", "/rest"]),
    "webgoat":      ("WebGoat",      "webgoat/webgoat",              "latest",          ["/WebGoat"]),
    "wrongsecrets": ("WrongSecrets", "jeroenwillemsen/wrongsecrets", "latest-no-vault", ["/"]),
}

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

api = sh("aws eks describe-cluster --name concert-demo --region us-east-1 --query cluster.endpoint --output text")
for a, (name, img, tag, endpoints) in APPS.items():
    digest = sh(f"kubectl get pod -n demo-apps -l app={a} -o jsonpath='{{.items[0].status.containerStatuses[0].imageID}}'").split("@")[-1]
    host = sh(f"kubectl get svc {a} -n demo-apps -o jsonpath='{{.status.loadBalancer.ingress[0].hostname}}'")
    port = int(sh(f"kubectl get svc {a} -n demo-apps -o jsonpath='{{.spec.ports[0].port}}'") or 80)
    sbom = {
        "bomFormat": "ConcertDef", "specVersion": "1.0.2",
        "metadata": {"timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "type": "application", "component": {"name": name, "version": "1.0.0"}},
        "runtime-components": [{
            "bom-ref": "service:kubernetes:eks:concert-demo", "name": "concert-demo", "type": "kubernetes", "api-server": api,
            "properties": [{"name": "platform", "value": "eks"}, {"name": "cluster_platform", "value": "kubernetes"},
                           {"name": "cluster_region", "value": "us-east-1"}, {"name": "cluster_name", "value": "concert-demo"}],
            "components": [{"type": "namespace", "name": "demo-apps", "components": [{
                "bom-ref": f"container:{img}", "type": "container", "name": img,
                "uri": f"{img}:{tag}@{digest}", "tag": tag, "digest": digest}]}]}],
        "environments": [{
            "bom-ref": "environment:production-eks", "type": "environment", "name": "production-eks",
            "access-points": [{"ref": f"appapi:{a}-web", "base-url": f"http://{host}", "port": port}],
            "properties": [{"name": "platform_type", "value": "eks"}, {"name": "deployment_purpose", "value": "production"}]}],
        "services": [{"bom-ref": f"appapi:{a}-web", "name": f"{a}-web", "endpoints": endpoints,
                      "properties": [{"name": "network_exposure", "value": "public"}]}],
        "dependencies": [{"ref": f"container:{img}", "dependsOn": [f"appapi:{a}-web"]}],
    }
    json.dump(sbom, open(f"{WORK}/{a}-deploy-sbom.json", "w"), indent=2)
    print(f"{a}: {img}@{digest[:19]} -> http://{host}:{port}")
