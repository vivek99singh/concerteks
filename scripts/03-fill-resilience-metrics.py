#!/usr/bin/env python3
"""Submit the resilience metrics that Kubernetes auto-discovery does not collect, for the three demo apps.

The Autodiscovery profile needs 54 metrics; discovery collects 14. The other 40 are derived from the
live pod specs and RBAC in namespace demo-apps (1 workload per app, so 0 or 100) and from the certificate
inventory. Hourly auto-assessments only reuse discovered metrics, so run this again shortly before a demo.

Usage: CONCERT_URL=https://<concert-host> CONCERT_API_KEY=<key> ./03-fill-resilience-metrics.py
"""
import datetime
import json
import os
import ssl
import urllib.error
import urllib.request

URL = os.environ["CONCERT_URL"].rstrip("/") + "/resilience/assessment/api/v1/evaluate"
KEY = os.environ["CONCERT_API_KEY"]
VERSION = os.environ.get("APP_VERSION", "1.1.0")
ENV = os.environ.get("ENVIRONMENT", "production-eks")

COMMON = {
    # securityContext is not set on the demo deployments
    "pct_workloads_with_privilege_escalation": 100, "pct_workloads_with_rootfs_not_read_only": 100,
    "pct_workloads_with_all_capabilities_drop": 0, "pct_workloads_with_default_seccomp_policies": 0,
    "pct_workloads_without_runtime_profile": 100, "pct_workloads_with_extra_capabilities_added": 0,
    "pct_workloads_with_only_net_bind_service": 0, "pct_workload_run_as_root": 0,
    "pct_workloads_with_root_primary_supplementary_gid": 0, "pct_workloads_with_binding_to_privileged_ports": 0,
    # no host access, no hostPath, only core volume types
    "pct_workloads_with_access_to_host_ipc_namespace": 0, "pct_workloads_with_access_to_host_network": 0,
    "pct_workloads_with_access_to_host_pid": 0, "pct_workloads_with_hostpath_volumes_mounted": 0,
    "pct_workloads_with_access_to_host_ports": 0, "pct_workloads_with_non_default_proc_masks": 0,
    "pct_workloads_with_non_core_volume_types": 0,
    # no Roles or RoleBindings in demo-apps
    "pct_rolebindings_with_admin_access": 0, "pct_clusterroles_managing_secrets": 0,
    "pct_roles_with_wildcard_verbs": 0, "pct_cluster_roles_with_manage_all_resources": 0,
    "pct_roles_allowing_privileges_escalation": 0, "pct_roles_managing_configmaps": 0,
    "pct_roles_allowing_exec_into_pods": 0, "pct_roles_managing_kubernetes_networking": 0,
    "pct_roles_with_manage_rbac_roles": 0, "pct_roles_with_manage_all_resources": 0,
    "pct_roles_managing_secrets": 0, "pct_roles_with_delete_log_permissions": 0,
    "pct_roles_with_wildcard_verb_on_wildcard_resources": 0, "pct_clusterroles_managing_webhooks": 0,
    # config maps hold no secrets; services are public LoadBalancers; usage far below limits
    "pct_configmap_with_sensitive_content": 0, "pct_configmaps_with_secrets": 0,
    "pct_services_with_external_ip": 100,
    "pct_workloads_within_90pct_cpu_limits": 100, "pct_workloads_within_90pct_memory_limits": 100,
    "num_certificates_expiring_in_one_day": 0, "num_certificates_expiring_in_one_week": 0,
}
CERTS = {  # from the certificate inventory uploaded by load-demo-data.sh
    "Juice Shop": {"num_certificates_expired": 1, "num_certificates_expiring_in_one_month": 0},
    "WebGoat": {"num_certificates_expired": 0, "num_certificates_expiring_in_one_month": 1},
    "WrongSecrets": {"num_certificates_expired": 0, "num_certificates_expiring_in_one_month": 1},
}

ctx = ssl._create_unverified_context()  # Concert uses a self-signed certificate
for app, certs in CERTS.items():
    body = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "profile": "auto_discovery_k8s_profile", "target_type": "app_deployment",
        "target": f"deploy_{ENV}_{app}_{VERSION}", "version": VERSION, "environment": ENV,
        "data": {k: str(v) for k, v in {**COMMON, **certs}.items()},
        "origin": "Manual", "custom_metadata": {"origin_name": "Concert", "origin_url": ""},
    }
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"C_API_KEY {KEY}", "InstanceID": "0000-0000-0000-0000", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            print(f"{app}: HTTP {r.status} {json.loads(r.read()).get('message')}")
    except urllib.error.HTTPError as e:
        print(f"{app}: HTTP {e.code} {e.read()[:300].decode()}")
