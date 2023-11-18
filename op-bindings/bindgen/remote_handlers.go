package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"

	"github.com/ethereum-optimism/optimism/op-bindings/etherscan"
)

type contractData struct {
	abi          string
	deployedBin  string
	deploymentTx etherscan.TxInfo
}

func (generator *bindGenGeneratorRemote) standardHandler(contractMetadata *remoteContractMetadata) error {
	fetchedData, err := generator.fetchContractData(contractMetadata.Verified, "eth", contractMetadata.Deployments["eth"], contractMetadata.DeploymentSalt)
	if err != nil {
		return err
	}

	contractMetadata.Abi = fetchedData.abi
	contractMetadata.DeployedBin = fetchedData.deployedBin
	contractMetadata.InitBin = fetchedData.deploymentTx.Input

	// We're not comparing the bytecode for Create2Deployer with deployment on OP,
	// because we're predeploying a modified version of Create2Deployer that has not yet been
	// deployed to OP.
	// For context: https://github.com/ethereum-optimism/op-geth/pull/126
	if contractMetadata.Name != "Create2Deployer" {
		if err := generator.compareBytecodeWithOp(contractMetadata); err != nil {
			return fmt.Errorf("error comparing contract bytecode for %s: %w", contractMetadata.Name, err)
		}
	}

	return generator.writeAllOutputs(contractMetadata, remoteContractMetadataTemplate)
}

func (generator *bindGenGeneratorRemote) multiSendHandler(contractMetadata *remoteContractMetadata) error {
	// MultiSend has an immutable that resolves to this(address).
	// Because we're predeploying MultiSend to the same address as on OP,
	// we can use the deployed bytecode directly for the predeploy
	fetchedData, err := generator.fetchContractData(contractMetadata.Verified, "op", contractMetadata.Deployments["op"], contractMetadata.DeploymentSalt)
	if err != nil {
		return err
	}

	contractMetadata.Abi = fetchedData.abi
	contractMetadata.DeployedBin = fetchedData.deployedBin
	contractMetadata.InitBin = fetchedData.deploymentTx.Input

	return generator.writeAllOutputs(contractMetadata, remoteContractMetadataTemplate)
}

func (generator *bindGenGeneratorRemote) senderCreatorHandler(contractMetadata *remoteContractMetadata) error {
	var err error
	contractMetadata.DeployedBin, err = generator.contractDataClient.FetchDeployedBytecode("eth", contractMetadata.Deployments["eth"])
	if err != nil {
		return fmt.Errorf("error fetching deployed bytecode: %w", err)
	}

	if err := generator.compareBytecodeWithOp(contractMetadata); err != nil {
		return fmt.Errorf("error comparing contract bytecode for %s: %w", contractMetadata.Name, err)
	}

	return generator.writeAllOutputs(contractMetadata, remoteContractMetadataTemplate)
}

func (generator *bindGenGeneratorRemote) permit2Handler(contractMetadata *remoteContractMetadata) error {
	fetchedData, err := generator.fetchContractData(contractMetadata.Verified, "eth", contractMetadata.Deployments["eth"], contractMetadata.DeploymentSalt)
	if err != nil {
		return err
	}

	contractMetadata.Abi = fetchedData.abi
	contractMetadata.InitBin = fetchedData.deploymentTx.Input

	if contractMetadata.DeployerAddress != fetchedData.deploymentTx.To {
		return fmt.Errorf(
			"expected deployer address: %s doesn't match the to address: %s for Permit2's proxy deployment transaction",
			contractMetadata.DeployerAddress,
			fetchedData.deploymentTx.To,
		)
	}

	if err := generator.compareBytecodeWithOp(
		contractMetadata,
	); err != nil {
		return fmt.Errorf("error comparing contract bytecode for %s: %w", contractMetadata.Name, err)
	}

	return generator.writeAllOutputs(contractMetadata, permit2MetadataTemplate)
}

func (generator *bindGenGeneratorRemote) fetchContractData(contractVerified bool, chain, deploymentAddress, deploymentSalt string) (contractData, error) {
	var data contractData
	var err error
	if contractVerified {
		data.abi, err = generator.contractDataClient.FetchAbi(chain, deploymentAddress)
		if err != nil {
			return contractData{}, fmt.Errorf("error fetching ABI: %w", err)
		}
	}

	data.deployedBin, err = generator.contractDataClient.FetchDeployedBytecode(chain, deploymentAddress)
	if err != nil {
		return contractData{}, fmt.Errorf("error fetching deployed bytecode: %w", err)
	}

	deploymentTxHash, err := generator.contractDataClient.FetchDeploymentTxHash(chain, deploymentAddress)
	if err != nil {
		return contractData{}, fmt.Errorf("error fetching deployment transaction hash: %w", err)
	}

	data.deploymentTx, err = generator.contractDataClient.FetchDeploymentTx(chain, deploymentTxHash)
	if err != nil {
		return contractData{}, fmt.Errorf("error fetching deployment transaction data: %w", err)
	}

	if deploymentSalt != "" {
		// Removing deployment salt from initialization bytecode
		re := regexp.MustCompile(fmt.Sprintf("^0x(%s)", deploymentSalt))
		if !re.MatchString(data.deploymentTx.Input) {
			return contractData{}, fmt.Errorf(
				"expected salt: %s to be at the beginning of the contract initialization code: %s, but it wasn't",
				deploymentSalt, data.deploymentTx.Input,
			)
		}
		data.deploymentTx.Input = re.ReplaceAllString(data.deploymentTx.Input, "")
	}

	return data, nil
}

func (generator *bindGenGeneratorRemote) compareBytecodeWithOp(contractMetadataEth *remoteContractMetadata) error {
	// Passing false here, because true will retrieve contract's ABI, but we don't need it for bytecode comparison
	opContractData, err := generator.fetchContractData(false, "op", contractMetadataEth.Deployments["op"], contractMetadataEth.DeploymentSalt)
	if err != nil {
		return err
	}

	if contractMetadataEth.InitBin != "" && contractMetadataEth.InitBin != opContractData.deploymentTx.Input {
		generator.logger.Crit(
			"Initialization bytecode on Ethereum doesn't match bytecode on Optimism",
			"contractName", contractMetadataEth.Name,
			"bytecodeEth", contractMetadataEth.InitBin,
			"bytecodeOp", opContractData.deploymentTx.Input,
		)
	}

	if contractMetadataEth.DeployedBin != "" && contractMetadataEth.DeployedBin != opContractData.deployedBin {
		generator.logger.Crit(
			"Deployed bytecode on Ethereum doesn't match bytecode on Optimism",
			"contractName", contractMetadataEth.Name,
			"bytecodeEth", contractMetadataEth.DeployedBin,
			"bytecodeOp", opContractData.deployedBin,
		)
	}

	return nil
}

func (generator *bindGenGeneratorRemote) writeAllOutputs(contractMetadata *remoteContractMetadata, fileTemplate string) error {
	abiFilePath, bytecodeFilePath, err := writeContractArtifacts(
		generator.logger, generator.tempArtifactsDir, contractMetadata.Name,
		[]byte(contractMetadata.Abi), []byte(contractMetadata.InitBin),
	)
	if err != nil {
		return err
	}

	err = genContractBindings(generator.logger, abiFilePath, bytecodeFilePath, generator.bindingsPackageName, contractMetadata.Name)
	if err != nil {
		return err
	}

	return generator.writeContractMetadata(
		contractMetadata,
		template.Must(template.New("remoteContractMetadata").Parse(fileTemplate)),
	)
}

func (generator *bindGenGeneratorRemote) writeContractMetadata(contractMetadata *remoteContractMetadata, fileTemplate *template.Template) error {
	metadataFilePath := filepath.Join(generator.metadataOut, strings.ToLower(contractMetadata.Name)+"_more.go")
	metadataFile, err := os.OpenFile(
		metadataFilePath,
		os.O_RDWR|os.O_CREATE|os.O_TRUNC,
		0o600,
	)
	if err != nil {
		return fmt.Errorf("error opening %s's metadata file at %s: %w", contractMetadata.Name, metadataFilePath, err)
	}
	defer metadataFile.Close()

	if err := fileTemplate.Execute(metadataFile, contractMetadata); err != nil {
		return fmt.Errorf("error writing %s's contract metadata at %s: %w", contractMetadata.Name, metadataFilePath, err)
	}

	generator.logger.Debug("Successfully wrote contract metadata", "contractName", contractMetadata.Name, "metadataFilePath", metadataFilePath)
	return nil
}

// remoteContractMetadataTemplate is a Go text template for generating the metadata
// associated with a remotely sourced contracts.
//
// The template expects the following data to be provided:
// - .Package: the name of the Go package.
// - .Name: the name of the contract.
// - .DeployedBin: the binary (hex-encoded) of the deployed contract.
var remoteContractMetadataTemplate = `// Code generated - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.

package {{.Package}}

var {{.Name}}DeployedBin = "{{.DeployedBin}}"
func init() {
	deployedBytecodes["{{.Name}}"] = {{.Name}}DeployedBin
}
`

// permit2MetadataTemplate is a Go text template used to generate metadata
// for remotely sourced Permit2 contract. Because Permit2 has an immutable
// Solidity variables that depends on block.chainid, we can't use the deployed
// bytecode, but instead need to generate it specifically for each chain.
// To help with this, the metadata contains the
//
// The template expects the following data to be provided:
// - .Package: the name of the Go package.
// - .Name: the name of the contract.
// - .InitBin: the binary (hex-encoded) of the contract's initialization code.
// - .DeploymentSalt: the salt used during the contract's deployment.
// - .DeployerAddress: the Ethereum address of the contract's deployer.
var permit2MetadataTemplate = `// Code generated - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.

package {{.Package}}

var {{.Name}}InitBin = "{{.InitBin}}"
var {{.Name}}DeploymentSalt = "{{.DeploymentSalt}}"
var {{.Name}}DeployerAddress = "{{.DeployerAddress}}"

func init() {
	initBytecodes["{{.Name}}"] = {{.Name}}InitBin
	deploymentSalts["{{.Name}}"] = {{.Name}}DeploymentSalt
	deployerAddresses["{{.Name}}"] = {{.Name}}DeployerAddress
}
`
