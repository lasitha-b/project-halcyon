#!/usr/bin/env python3
"""Project Halcyon — AWS deployment path: generate an Ansible inventory.

Reads `terraform output -json` (run from terraform/) plus the local SSM
tunnel port map (ansible/generated/tunnel_ports.json, written by
scripts/aws-deploy.sh) and emits ansible/generated/inventory_aws.yml in
EXACTLY the group shape of ansible/inventory.yml (children: windows/linux/
attacker, nested domain_controllers/member_servers/clients), so
ansible/site.yml runs completely unmodified against it.

Every host is addressed as 127.0.0.1:<tunnel-port> — Ansible talks to each
guest over its own SSM Session Manager port-forward tunnel, never directly
over the VPC, mirroring the KVM host's out-of-band ".1 management adapter on
every network" reachability trick without needing a bastion instance.
"""
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = REPO_ROOT / "terraform"
GENERATED_DIR = REPO_ROOT / "ansible" / "generated"
PORTS_FILE = GENERATED_DIR / "tunnel_ports.json"


def terraform_output() -> dict:
    raw = subprocess.check_output(
        ["terraform", f"-chdir={TERRAFORM_DIR}", "output", "-json"],
        text=True,
    )
    return json.loads(raw)


def load_ports() -> dict:
    if not PORTS_FILE.exists():
        sys.exit(
            f"[aws-gen-inventory] {PORTS_FILE} not found — "
            "run this after scripts/aws-deploy.sh has opened SSM tunnels."
        )
    return json.loads(PORTS_FILE.read_text())


def build_inventory(tf_out: dict, ports: dict) -> dict:
    hosts = tf_out["hosts"]["value"]
    bootstrap_password = tf_out["windows_bootstrap_password"]["value"]

    def win_host(name: str) -> dict:
        return {"ansible_host": "127.0.0.1", "ansible_port": ports[name]}

    def lin_host(name: str) -> dict:
        return {"ansible_host": "127.0.0.1", "ansible_port": ports[name]}

    domain_controllers = {
        n: win_host(n) for n, h in hosts.items() if h["group"] == "domain_controllers"
    }
    member_servers = {
        n: win_host(n) for n, h in hosts.items() if h["group"] == "member_servers"
    }
    clients = {n: win_host(n) for n, h in hosts.items() if h["group"] == "clients"}
    linux_hosts = {n: lin_host(n) for n, h in hosts.items() if h["group"] == "linux"}
    attacker_hosts = {
        n: lin_host(n) for n, h in hosts.items() if h["group"] == "attacker"
    }

    return {
        "all": {
            "vars": {
                "domain_name": "corp.halcyon.local",
                "domain_netbios": "HALCYON",
                "org_name": "Halcyon Logistics",
            },
            "children": {
                "windows": {
                    "vars": {
                        "ansible_connection": "winrm",
                        "ansible_user": "vagrant",
                        "ansible_password": bootstrap_password,
                        "ansible_winrm_transport": "ntlm",
                        "ansible_winrm_server_cert_validation": "ignore",
                    },
                    "children": {
                        "domain_controllers": {"hosts": domain_controllers},
                        "member_servers": {"hosts": member_servers},
                        "clients": {"hosts": clients},
                    },
                },
                "linux": {
                    "vars": {
                        "ansible_connection": "ssh",
                        "ansible_user": "vagrant",
                        "ansible_ssh_private_key_file": tf_out["ssh_private_key_hint"][
                            "value"
                        ],
                        "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
                        "ansible_become": True,
                    },
                    "hosts": linux_hosts,
                },
                "attacker": {
                    "vars": {
                        "ansible_connection": "ssh",
                        "ansible_user": "kali",
                        "ansible_ssh_private_key_file": tf_out["ssh_private_key_hint"][
                            "value"
                        ],
                        "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null",
                    },
                    "hosts": attacker_hosts,
                },
            },
        }
    }


def to_yaml(data: dict, indent: int = 0) -> str:
    """Minimal, dependency-free YAML emitter (avoids requiring PyYAML on the
    control node just for this one generated file)."""
    lines = []
    pad = "  " * indent
    for key, value in data.items():
        if isinstance(value, dict):
            if not value:
                lines.append(f"{pad}{key}: {{}}")
            else:
                lines.append(f"{pad}{key}:")
                lines.append(to_yaml(value, indent + 1))
        elif isinstance(value, bool):
            lines.append(f"{pad}{key}: {'true' if value else 'false'}")
        else:
            lines.append(f'{pad}{key}: "{value}"')
    return "\n".join(lines)


def main() -> None:
    tf_out = terraform_output()
    ports = load_ports()
    inventory = build_inventory(tf_out, ports)

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    out_path = GENERATED_DIR / "inventory_aws.yml"
    out_path.write_text(to_yaml(inventory) + "\n")
    print(f"[aws-gen-inventory] wrote {out_path}")


if __name__ == "__main__":
    main()
