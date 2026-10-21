#!/usr/bin/env python3
"""Inject QA_* environment variables from the CI environment into the built xctestrun."""
import glob
import os
import plistlib
import sys


def main() -> int:
    path = glob.glob(os.environ.get("XCTRUN_GLOB", "dd/Build/Products/*-*.xctestrun"))
    if not path:
        print("no xctestrun found", file=sys.stderr)
        return 1
    path = path[0]
    print("xctestrun:", path)

    env = {k: os.environ[k] for k in ("QA_SERVER_URL", "QA_USER", "QA_PASS") if k in os.environ}
    if not env:
        print("no QA_* vars in environment", file=sys.stderr)
        return 1

    with open(path, "rb") as handle:
        data = plistlib.load(handle)

    injected = 0
    for section in data.values():
        if not isinstance(section, dict):
            continue
        # Flat format (Xcode 15-27): target-level EnvironmentVariables.
        if "EnvironmentVariables" in section or "TestBundlePath" in section:
            section.setdefault("EnvironmentVariables", {}).update(env)
            injected += 1
        # Nested format (newer variants): TestConfigurations/<cfg>/EnvironmentVariables.
        test_configs = section.get("TestConfigurations")
        if isinstance(test_configs, dict):
            test_configs.setdefault("EnvironmentVariables", {}).update(env)
            for cfg in (test_configs.get("TestConfigurationData") or {}).values():
                if isinstance(cfg, dict):
                    cfg.setdefault("EnvironmentVariables", {}).update(env)
            injected += 1

    with open(path, "wb") as handle:
        plistlib.dump(data, handle)

    # Fail loudly rather than let the run proceed on fallback defaults.
    with open(path, "rb") as handle:
        check = plistlib.load(handle)
    wanted = env.get("QA_SERVER_URL")

    def has_env(sec: object) -> bool:
        if not isinstance(sec, dict):
            return False
        if (sec.get("EnvironmentVariables") or {}).get("QA_SERVER_URL") == wanted:
            return True
        tc = sec.get("TestConfigurations")
        if isinstance(tc, dict):
            if (tc.get("EnvironmentVariables") or {}).get("QA_SERVER_URL") == wanted:
                return True
            for cfg in (tc.get("TestConfigurationData") or {}).values():
                if isinstance(cfg, dict) and (cfg.get("EnvironmentVariables") or {}).get("QA_SERVER_URL") == wanted:
                    return True
        return False

    verified = any(has_env(sec) for sec in check.values())
    if wanted and not verified:
        print("injection verification FAILED", file=sys.stderr)
        return 1
    print(f"env injected into {injected} section(s):", ", ".join(sorted(env)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
