.PHONY: check

check:
	cyrograf format --check contracts
	cyrograf check contracts
