update-abis:
	jq '.abi' AxelarHandler/out/AxelarHandler.sol/AxelarHandler.json > abi/AxelarHandler.json
	jq '.abi' AxelarHandler/out/GoFastHandler.sol/GoFastHandler.json > abi/GoFastHandler.json
	jq '.abi' CCTPRelayer/out/CCTPRelayer.sol/CCTPRelayer.json > abi/CCTPRelayer.json
	jq '.abi' CCTPV2Relayer/out/CCTPV2Relayer.sol/CCTPV2Relayer.json > abi/CCTPV2Relayer.json
	jq '.abi' EurekaHandler/out/EurekaHandler.sol/EurekaHandler.json > abi/EurekaHandler.json
	jq '.abi' SwapRouter/out/SkipGoSwapRouter.sol/SkipGoSwapRouter.json > abi/SkipGoSwapRouter.json
	jq '.abi' ForwarderFactory/out/InboundForwarder.sol/InboundForwarder.json > abi/InboundForwarder.json
	jq '.abi' ForwarderFactory/out/InboundForwarderFactory.sol/InboundForwarderFactory.json > abi/InboundForwarderFactory.json
	jq '.abi' ForwarderFactory/out/OutboundForwarder.sol/OutboundForwarder.json > abi/OutboundForwarder.json
	jq '.abi' ForwarderFactory/out/OutboundForwarderFactory.sol/OutboundForwarderFactory.json > abi/OutboundForwarderFactory.json
	jq '.abi' TransitForwarder/out/TransitExecutor.sol/TransitExecutor.json > abi/TransitExecutor.json
	jq '.abi' TransitForwarder/out/TransitForwarder.sol/TransitForwarder.json > abi/TransitForwarder.json
	jq '.abi' TransitForwarder/out/TransitForwarderFactory.sol/TransitForwarderFactory.json > abi/TransitForwarderFactory.json

# ── TransitForwarder copy integrity ───────────────────────────────────────────────────────────────────────────
# TransitForwarder/ is a short-lived subproject that deliberately shares no source with ForwarderFactory/, so a
# handful of files are duplicated instead of imported. Duplication's one real hazard is silent drift, and this
# target is what makes the duplication safe to live with. Run it in CI, not only by hand.
#
# ⚠️ TransitForwarder targets AVALANCHE C-Chain and POLYGON PoS while ForwarderFactory targets Injective EVM. That is why
#    script/Config.sol is NOT compared here: its addresses SHOULD differ, so a value comparison would be pure noise
#    (and would train people to ignore this target). Config has no upstream to drift from — it is chain-specific
#    truth, verified by review and by _assertTransitImmutablesMatch against what is actually deployed.
#
# Two checks remain, because two things genuinely must not diverge:
#   VERBATIM  — chain-agnostic sources that are literal copies. `diff` printing nothing IS the review of these files.
#   SETTINGS  — foundry.toml's build settings feed type(BeaconProxy).creationCode, so they must match the sibling for
#               the shared golden vector to stay valid. Only the settings, never the comments: the comments must
#               differ (they describe different target chains).
#
#               NOT copied: anything mint-side. The siblings receive CCTP v2; Transit's mint leg is CCTP v1, a
#               different Circle contract with an unrelated message layout. So CCTPV1Message.sol is original code
#               with its own golden vector, and IReceiver.sol is no longer frozen against the v2 sibling — the
#               function signature happens to match, but freezing it would force its documentation to describe the
#               wrong protocol. The burn-side copy IS still frozen, because that leg IS v2 — but it is now
#               ITokenMessenger.sol, not ICCTPV2Relayer.sol: TransitForwarder charges no relayer fee, so it calls
#               Circle's messenger directly instead of delegating to the fee-collecting relayer.
# Entries are <upstream-project>:<path-relative-to-both-projects>. The upstream differs per file: the messenger
# interface is owned by CCTPV2Relayer (it is that project's burn leg), while remappings.txt must track the
# ForwarderFactory sibling because it feeds type(BeaconProxy).creationCode and therefore the shared golden vector.
TRANSIT_VERBATIM_FILES = \
	CCTPV2Relayer:src/interfaces/ITokenMessenger.sol \
	ForwarderFactory:remappings.txt

TRANSIT_BUILD_SETTINGS = solc evm_version optimizer optimizer_runs via_ir auto_detect_remappings

check-transit-copies:
	@fail=0; \
	for e in $(TRANSIT_VERBATIM_FILES); do \
		up=$${e%%:*}; f=$${e#*:}; \
		if diff -q $$up/$$f TransitForwarder/$$f >/dev/null 2>&1; then \
			echo "  ok       $$f  (upstream: $$up)"; \
		else \
			echo "  DRIFTED  $$f  (upstream: $$up)"; \
			diff $$up/$$f TransitForwarder/$$f || true; \
			fail=1; \
		fi; \
	done; \
	for k in $(TRANSIT_BUILD_SETTINGS); do \
		a=$$(grep -E "^$$k *=" ForwarderFactory/foundry.toml | head -1 | sed -E 's/^[^=]*= *//'); \
		b=$$(grep -E "^$$k *=" TransitForwarder/foundry.toml | head -1 | sed -E 's/^[^=]*= *//'); \
		if [ -z "$$a" ] || [ -z "$$b" ]; then \
			echo "  MISSING  foundry.toml:$$k (ForwarderFactory='$$a' TransitForwarder='$$b')"; fail=1; \
		elif [ "$$a" = "$$b" ]; then \
			echo "  ok       foundry.toml:$$k = $$a"; \
		else \
			echo "  DRIFTED  foundry.toml:$$k: ForwarderFactory=$$a TransitForwarder=$$b"; fail=1; \
		fi; \
	done; \
	if [ $$fail -ne 0 ]; then \
		echo ""; \
		echo "TransitForwarder has drifted from its upstream (named per line above)."; \
		echo "For a VERBATIM file: re-copy from the original — do NOT hand-edit the copy (design doc DD-7)."; \
		echo "For a build SETTING: a mismatch invalidates the shared golden vector; re-measure or revert."; \
		exit 1; \
	fi; \
	echo "TransitForwarder copies and build settings are in sync."

.PHONY: update-abis check-transit-copies
