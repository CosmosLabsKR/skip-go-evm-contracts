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