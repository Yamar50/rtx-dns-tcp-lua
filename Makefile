LUA ?= lua
PYTHON ?= python3

.PHONY: test build release nvr-test installer
test:
	$(LUA) tests/test_installer_sha256.lua
	$(LUA) tests/test_installer_http.lua
	$(LUA) tests/test_installer.lua
	$(LUA) tests/test_interfaces.lua
	$(LUA) tests/test_wire_cache.lua
	$(LUA) tests/test_dns_policy.lua
	$(LUA) tests/test_dynamic_policy.lua
	$(LUA) tests/test_ipv6_fallback.lua
	$(LUA) tests/test_dns_runtime.lua
	$(LUA) tests/test_aaaa_filter.lua
	$(LUA) tests/test_auto_config.lua
	$(LUA) tests/test_nvr_compat.lua
	$(LUA) tests/test_policy_wire.lua
	$(LUA) tests/test_main.lua
	$(LUA) tests/test_relay.lua
	$(LUA) tests/cache_memory.lua
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py'
	$(PYTHON) -m py_compile tools/build.py tools/serve_artifact.py tools/summarize_run.py tools/plot_load.py tests/integration.py tests/live_scenarios.py tests/resilience_scenarios.py

build:
	$(PYTHON) tools/build.py --config config/example.lua --output build/rtx-dns.lua

release:
	$(PYTHON) tools/build.py --config config/release.lua --output build/release/rtx-dns.lua

nvr-test:
	$(PYTHON) tools/build.py --config config/nvr-test.lua --output build/nvr-test/nvr-dns.lua

installer:
	$(PYTHON) tools/build_installer.py
