import fileinput
import os
import re
import shutil
import subprocess

import jinja2
import typer
from typing_extensions import Annotated
from web3 import Web3

work_dir = os.getcwd()
if work_dir.endswith("scripts"):
    work_dir = work_dir[:-8]

network: str
chain_id: int
hex_chain_id: str
ens_registry_owner: str

main = typer.Typer()


def backup_file(source, destination):
    try:
        shutil.copyfile(source, destination)
    except FileNotFoundError:
        print(f"Source file '{source}' not found.")
    except PermissionError:
        print(f"Permission error: Unable to copy file '{source}' to '{destination}'.")
    except Exception as e:
        print(f"An error occurred: {e}")


def insert(contract, pattern, ins):
    pattern = re.compile(pattern)
    filepath = os.path.join(work_dir, "contracts", contract)

    found = False
    with fileinput.FileInput(filepath, inplace=True) as file:
        for line in file:
            if not found and pattern.search(line):
                print(ins)
                found = True
            print(line, end="")

    if not found:
        raise Exception(f"{pattern} not found")


def replace(contract, pattern, repl, count=1):
    pattern = re.compile(pattern)
    filepath = os.path.join(work_dir, "contracts", contract)

    with open(filepath, "r") as f:
        content = f.read()

    if pattern.search(content):
        content = pattern.sub(repl, content, count=count)
    else:
        raise Exception(f"{pattern} not found")

    with open(filepath, "w") as f:
        f.write(content)


def replace_parameter(contract, parameter, value):
    pattern = f"{parameter} =[^;]*;"
    repl = f"{parameter} = {value};"

    replace(contract, pattern, repl)


def convert_chain_id(int_chain_id: int):
    try:
        hex_representation = hex(int_chain_id)[2:]
        padded_hex = hex_representation.zfill(4)
        return padded_hex
    except Exception as e:
        print(f"Error converting {int_chain_id} to hex: {e}")
        return None


def generate_from_template(data, template_file, output_file):
    template_loader = jinja2.FileSystemLoader(work_dir)
    template_env = jinja2.Environment(loader=template_loader, autoescape=True)

    template = template_env.get_template(template_file)
    result_string = template.render(data)

    output_path = os.path.join(work_dir, output_file)
    with open(output_path, "w") as output_file:
        output_file.write(result_string)


def generate_slash_indicator(misdemeanor_threshold, felony_threshold, init_felony_slash_scope):
    contract = "SlashIndicator.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint256 public constant MISDEMEANOR_THRESHOLD", f"{misdemeanor_threshold}")
    replace_parameter(contract, "uint256 public constant FELONY_THRESHOLD", f"{felony_threshold}")
    replace_parameter(contract, "uint256 public constant INIT_FELONY_SLASH_SCOPE", f"{init_felony_slash_scope}")

    if network == "dev":
        insert(contract, "alreadyInit = true;", "\t\tenableMaliciousVoteSlash = true;")


def generate_stake_hub(
    breathe_block_interval, max_elected_validators, unbond_period, downtime_jail_time, felony_jail_time,
    stake_hub_protector
):
    contract = "StakeHub.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint256 public constant BREATHE_BLOCK_INTERVAL", f"{breathe_block_interval}")

    replace(contract, r"maxElectedValidators = .*;", f"maxElectedValidators = {max_elected_validators};")
    replace(contract, r"unbondPeriod = .*;", f"unbondPeriod = {unbond_period};")
    replace(contract, r"downtimeJailTime = .*;", f"downtimeJailTime = {downtime_jail_time};")
    replace(contract, r"felonyJailTime = .*;", f"felonyJailTime = {felony_jail_time};")
    replace(contract, r"__Protectable_init_unchained\(.*\);", f"__Protectable_init_unchained({stake_hub_protector});")


def generate_governor(
    block_interval, init_voting_delay, init_voting_period, init_proposal_threshold, init_quorum_numerator,
    propose_start_threshold, init_min_period_after_quorum, governor_protector
):
    contract = "L2PGovernor.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint256 private constant BLOCK_INTERVAL", f"{block_interval}")
    replace_parameter(contract, "uint256 private constant INIT_VOTING_DELAY", f"{init_voting_delay}")
    replace_parameter(contract, "uint256 private constant INIT_VOTING_PERIOD", f"{init_voting_period}")
    replace_parameter(contract, "uint256 private constant INIT_PROPOSAL_THRESHOLD", f"{init_proposal_threshold}")
    replace_parameter(contract, "uint256 private constant INIT_QUORUM_NUMERATOR", f"{init_quorum_numerator}")
    replace_parameter(
        contract, "uint256 private constant PROPOSE_START_GOVL2P_SUPPLY_THRESHOLD", f"{propose_start_threshold}"
    )
    replace_parameter(
        contract, "uint64 private constant INIT_MIN_PERIOD_AFTER_QUORUM", f"{init_min_period_after_quorum}"
    )
    replace(contract, r"__Protectable_init_unchained\(.*\);", f"__Protectable_init_unchained({governor_protector});")


def generate_timelock(init_minimal_delay):
    contract = "L2PTimelock.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint256 private constant INIT_MINIMAL_DELAY", f"{init_minimal_delay}")


def generate_system():
    contract = "System.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint16 public constant l2pChainID", f"0x{hex_chain_id}")


def generate_system_reward():
    if network == "dev":
        contract = "SystemReward.sol"
        backup_file(
            os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
        )

        insert(contract, "numOperator = 2;", "\t\toperators[VALIDATOR_CONTRACT_ADDR] = true;")
        insert(contract, "numOperator = 2;", "\t\toperators[SLASH_CONTRACT_ADDR] = true;")
        replace(contract, "numOperator = 2;", "numOperator = 4;")


def generate_validator_set(init_validator_set_bytes, init_burn_ratio):
    contract = "L2PValidatorSet.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )

    replace_parameter(contract, "uint256 public constant INIT_BURN_RATIO", f"{init_burn_ratio}")
    replace_parameter(contract, "bytes public constant INIT_VALIDATORSET_BYTES", f"hex\"{init_validator_set_bytes}\"")

    if network == "dev":
        insert(
            contract, r"for \(uint256 i; i < validatorSetPkg\.validatorSet\.length; \+\+i\)",
            "\t\tValidatorExtra memory validatorExtra;"
        )
        insert(
            contract, r"currentValidatorSet\.push\(validatorSetPkg.validatorSet\[i\]\);",
            "\t\t\tvalidatorExtraSet.push(validatorExtra);"
        )
        insert(
            contract, r"currentValidatorSet\.push\(validatorSetPkg.validatorSet\[i\]\);",
            "\t\t\tvalidatorExtraSet[i].voteAddress=validatorSetPkg.voteAddrs[i];"
        )


def generate_gov_hub():
    contract = "GovHub.sol"
    backup_file(
        os.path.join(work_dir, "contracts", contract), os.path.join(work_dir, "contracts", contract[:-4] + ".bak")
    )


def generate_genesis(output="./genesis.json"):
    subprocess.run(["forge", "build"], cwd=work_dir, check=True)
    subprocess.run(["node", "scripts/generate-genesis.js", "--chainId", f"{chain_id}", "--ensRegistryOwner", f"{ens_registry_owner}", "--output", f"{output}"], cwd=work_dir, check=True)


@main.command(help="Generate contracts for L2P mainnet")
def mainnet():
    global network, chain_id, hex_chain_id, ens_registry_owner
    network = "mainnet"
    chain_id = 12216
    ens_registry_owner = "0x1B272dC2635CFBE67116434CdBfD7525f8F5196F"
    hex_chain_id = convert_chain_id(chain_id)

    # mainnet init data
    init_burn_ratio = "1000"
    init_validator_set_bytes = "f9016380f9015ff87394ae11fb1f89c83c3ad49636a283732a3692de76f994ae11fb1f89c83c3ad49636a283732a3692de76f994ae11fb1f89c83c3ad49636a283732a3692de76f98207d1b0b990452e4365ee99b1ae0bef9ade1639c45f9560a7e334abad2b802ae3b6ae53d8a613924e3d94716287438e44aef774f8739498803ed812d591b5dcc319652645036b6ca32d1b9498803ed812d591b5dcc319652645036b6ca32d1b9498803ed812d591b5dcc319652645036b6ca32d1b8207d1b084a27e33f9a4d177ece0792106c648c1b91937782b119e06aa274485798f60bac26b1363656ecf8ecdabade91b292326f87394da209d1508a1680be75751d0a9923d74997d90f294da209d1508a1680be75751d0a9923d74997d90f294da209d1508a1680be75751d0a9923d74997d90f28207d1b0ab314870c4485be98da76207e4bcbbff0e45506631966e27f9424105351f8a66c44177e1e9f58038878308eee1a3ce77"
    source_chain_id = "Binance-Chain-Tigris"

    block_interval = "3 seconds"
    breathe_block_interval = "1 days"
    max_elected_validators = "45"
    unbond_period = "7 days"
    downtime_jail_time = "2 days"
    felony_jail_time = "30 days"
    init_felony_slash_scope = "28800"
    misdemeanor_threshold = "50"
    felony_threshold = "150"
    init_voting_delay = "0 hours / BLOCK_INTERVAL"
    init_voting_period = "7 days / BLOCK_INTERVAL"
    init_proposal_threshold = "200 ether"
    init_quorum_numerator = "10"
    propose_start_threshold = "10_000_000 ether"
    init_min_period_after_quorum = "uint64(1 days / BLOCK_INTERVAL)"
    init_minimal_delay = "24 hours"
    lock_period_for_token_recover = "7 days"

    stake_hub_protector = "0xC27bD3c844842C0D376bF419087F9E98231D4693"
    governor_protector = "0xC27bD3c844842C0D376bF419087F9E98231D4693"
    token_recover_portal_protector = "0xC27bD3c844842C0D376bF419087F9E98231D4693"

    generate_system()
    generate_system_reward()
    generate_gov_hub()
    generate_slash_indicator(misdemeanor_threshold, felony_threshold, init_felony_slash_scope)
    generate_validator_set(init_validator_set_bytes, init_burn_ratio)
    generate_stake_hub(
        breathe_block_interval, max_elected_validators, unbond_period, downtime_jail_time, felony_jail_time,
        stake_hub_protector
    )
    generate_governor(
        block_interval, init_voting_delay, init_voting_period, init_proposal_threshold, init_quorum_numerator,
        propose_start_threshold, init_min_period_after_quorum, governor_protector
    )
    generate_timelock(init_minimal_delay)

    generate_genesis()
    print("Generate genesis of mainnet successfully")


@main.command(help="Generate contracts for L2P testnet")
def testnet():
    global network, chain_id, hex_chain_id
    network = "testnet"
    chain_id = 97
    hex_chain_id = convert_chain_id(chain_id)

    # testnet init data
    init_burn_ratio = "1000"
    init_validator_set_bytes = "f901a880f901a4f844941284214b9b9c85549ab3d2b972df0deef66ac2c9946ddf42a51534fc98d0c0a3b42c963cace8441ddf946ddf42a51534fc98d0c0a3b42c963cace8441ddf8410000000f84494a2959d3f95eae5dc7d70144ce1b73b403b7eb6e0948081ef03f1d9e0bb4a5bf38f16285c879299f07f948081ef03f1d9e0bb4a5bf38f16285c879299f07f8410000000f8449435552c16704d214347f29fa77f77da6d75d7c75294dc4973e838e3949c77aced16ac2315dc2d7ab11194dc4973e838e3949c77aced16ac2315dc2d7ab1118410000000f84494980a75ecd1309ea12fa2ed87a8744fbfc9b863d594cc6ac05c95a99c1f7b5f88de0e3486c82293b27094cc6ac05c95a99c1f7b5f88de0e3486c82293b2708410000000f84494f474cf03cceff28abc65c9cbae594f725c80e12d94e61a183325a18a173319dd8e19c8d069459e217594e61a183325a18a173319dd8e19c8d069459e21758410000000f84494b71b214cb885500844365e95cd9942c7276e7fd894d22ca3ba2141d23adab65ce4940eb7665ea2b6a794d22ca3ba2141d23adab65ce4940eb7665ea2b6a78410000000"
    source_chain_id = "Binance-Chain-Ganges"

    block_interval = "3 seconds"
    breathe_block_interval = "1 days"
    max_elected_validators = "9"
    unbond_period = "7 days"
    downtime_jail_time = "2 days"
    felony_jail_time = "5 days"
    init_felony_slash_scope = "28800"
    misdemeanor_threshold = "50"
    felony_threshold = "150"
    init_voting_delay = "0 hours / BLOCK_INTERVAL"
    init_voting_period = "1 days / BLOCK_INTERVAL"
    init_proposal_threshold = "100 ether"
    init_quorum_numerator = "10"
    propose_start_threshold = "10_000_000 ether"
    init_min_period_after_quorum = "uint64(1 hours / BLOCK_INTERVAL)"
    init_minimal_delay = "6 hours"
    lock_period_for_token_recover = "300 seconds"

    stake_hub_protector = "0x30151DA466EC8AB345BEF3d6983023E050fb0673"
    governor_protector = "0x30151DA466EC8AB345BEF3d6983023E050fb0673"
    token_recover_portal_protector = "0x30151DA466EC8AB345BEF3d6983023E050fb0673"

    generate_system()
    generate_system_reward()
    generate_gov_hub()
    generate_slash_indicator(misdemeanor_threshold, felony_threshold, init_felony_slash_scope)
    generate_validator_set(init_validator_set_bytes, init_burn_ratio)
    generate_stake_hub(
        breathe_block_interval, max_elected_validators, unbond_period, downtime_jail_time, felony_jail_time,
        stake_hub_protector
    )
    generate_governor(
        block_interval, init_voting_delay, init_voting_period, init_proposal_threshold, init_quorum_numerator,
        propose_start_threshold, init_min_period_after_quorum, governor_protector
    )
    generate_timelock(init_minimal_delay)

    generate_genesis("./genesis-testnet.json")
    print("Generate genesis of testnet successfully")


@main.command(help="Generate contracts for dev environment")
def dev(
    dev_chain_id: int = 714,
    init_burn_ratio: Annotated[str, typer.Option(help="init burn ratio of L2pValidatorSet")] = "1000",
    source_chain_id: Annotated[
        str, typer.Option(help="source chain id of the token recover portal")] = "Binance-Chain-Ganges",
    stake_hub_protector: Annotated[str, typer.Option(help="assetProtector of StakeHub")] = "address(0xdEaD)",
    governor_protector: Annotated[str, typer.Option(help="governorProtector of L2PGovernor")] = "address(0xdEaD)",
    block_interval: Annotated[str, typer.Option(help="block interval of Parlia")] = "3 seconds",
    breathe_block_interval: Annotated[str, typer.Option(help="breath block interval of Parlia")] = "1 days",
    max_elected_validators: Annotated[str, typer.Option(help="maxElectedValidators of StakeHub")] = "45",
    unbond_period: Annotated[str, typer.Option(help="unbondPeriod of StakeHub")] = "7 days",
    downtime_jail_time: Annotated[str, typer.Option(help="downtimeJailTime of StakeHub")] = "2 days",
    felony_jail_time: Annotated[str, typer.Option(help="felonyJailTime of StakeHub")] = "30 days",
    init_felony_slash_scope: str = "28800",
    misdemeanor_threshold: str = "50",
    felony_threshold: str = "150",
    init_voting_delay: Annotated[str,
                                 typer.Option(help="INIT_VOTING_DELAY of L2PGovernor")] = "0 hours / BLOCK_INTERVAL",
    init_voting_period: Annotated[str,
                                  typer.Option(help="INIT_VOTING_PERIOD of L2PGovernor")] = "7 days / BLOCK_INTERVAL",
    init_proposal_threshold: Annotated[str, typer.Option(help="INIT_PROPOSAL_THRESHOLD of L2PGovernor")] = "200 ether",
    init_quorum_numerator: Annotated[str, typer.Option(help="INIT_QUORUM_NUMERATOR of L2PGovernor")] = "10",
    propose_start_threshold: Annotated[
        str, typer.Option(help="PROPOSE_START_GOVL2P_SUPPLY_THRESHOLD of L2PGovernor")] = "10_000_000 ether",
    init_min_period_after_quorum: Annotated[
        str, typer.Option(help="INIT_MIN_PERIOD_AFTER_QUORUM of L2PGovernor")] = "uint64(1 days / BLOCK_INTERVAL)",
    init_minimal_delay: Annotated[str, typer.Option(help="INIT_MINIMAL_DELAY of L2PTimelock")] = "24 hours"
):
    global network, chain_id, hex_chain_id
    network = "dev"
    chain_id = dev_chain_id
    hex_chain_id = convert_chain_id(chain_id)

    try:
        result = subprocess.run(
            [
                "node", "-e",
                "const exportsObj = require(\'./scripts/validators.js\'); console.log(exportsObj.validatorSetBytes.toString(\'hex\'));"
            ],
            capture_output=True,
            text=True,
            check=True,
            cwd=work_dir
        )
        init_validator_set_bytes = result.stdout.strip()[2:]
    except subprocess.CalledProcessError as e:
        raise Exception(f"Error getting init_validatorset_bytes: {e}")

    generate_system()
    generate_system_reward()
    generate_gov_hub()
    generate_slash_indicator(misdemeanor_threshold, felony_threshold, init_felony_slash_scope)
    generate_validator_set(init_validator_set_bytes, init_burn_ratio)
    generate_stake_hub(
        breathe_block_interval, max_elected_validators, unbond_period, downtime_jail_time, felony_jail_time,
        stake_hub_protector
    )
    generate_governor(
        block_interval, init_voting_delay, init_voting_period, init_proposal_threshold, init_quorum_numerator,
        propose_start_threshold, init_min_period_after_quorum, governor_protector
    )
    generate_timelock(init_minimal_delay)

    generate_genesis("./genesis-dev.json")
    print("Generate genesis of dev environment successfully")


@main.command(help="Recover from the backup")
def recover():
    contracts_dir = os.path.join(work_dir, "contracts")
    for file in os.listdir(contracts_dir):
        if file.endswith(".bak"):
            c_file = file[:-4] + ".sol"
            shutil.copyfile(os.path.join(contracts_dir, file), os.path.join(contracts_dir, c_file))
            os.remove(os.path.join(contracts_dir, file))

    print("Recover from the backup successfully")


@main.command(help="Generate init holders")
def generate_init_holders(
    init_holders: Annotated[str, typer.Argument(help="A list of addresses separated by comma")],
    template_file: str = "./scripts/init_holders.template",
    output_file: str = "./scripts/init_holders.js"
):
    init_holders = init_holders.split(",")
    data = {
        "initHolders": init_holders,
    }

    generate_from_template(data, template_file, output_file)
    print("Generate init holders successfully")


@main.command(help="Generate validators")
def generate_validators(
    file_path: str = "./validators.conf",
    template_file: str = "./scripts/validators.template",
    output_file: str = "./scripts/validators.js"
):
    file_path = os.path.join(work_dir, file_path)
    validators = []

    with open(file_path, "r") as file:
        for line in file:
            vs = line.strip().split(",")
            if len(vs) != 5:
                raise Exception(f"Invalid validator info: {line}")
            validators.append(
                {
                    "consensusAddr": vs[0],
                    "feeAddr": vs[1],
                    "l2pFeeAddr": vs[2],
                    "votingPower": vs[3],
                    "bLSPublicKey": vs[4],
                }
            )

    data = {
        "validators": validators,
    }

    generate_from_template(data, template_file, output_file)
    print("Generate validators successfully")


@main.command(help="Generate errors signature")
def generate_error_sig(dir_path: str = "./contracts"):
    dir_path = os.path.join(work_dir, dir_path)

    annotation_prefix = "    // @notice signature: "
    error_pattern = re.compile(r"^\s{4}(error)\s([a-zA-Z]*\(.*\));\s$")
    annotation_pattern = re.compile(r"^\s{4}(//\s@notice\ssignature:)\s.*\s$")
    for file in os.listdir(dir_path):
        if file.endswith(".sol"):
            file_path = os.path.join(dir_path, file)
            with open(file_path) as f:
                content = f.readlines()
            for i, line in enumerate(content):
                if error_pattern.match(line):
                    error_msg = line[10:-2]
                    # remove variable names
                    match = re.search(r"\((.*?)\)", error_msg)
                    if match and match.group(1) != "":
                        variables = [v.split()[0].strip() for v in match.group(1).split(",")]
                        error_msg = re.sub(r"\((.*?)\)", f"({','.join(variables)})", error_msg)
                    sig = Web3.keccak(text=error_msg)[:4].hex()
                    annotation = annotation_prefix + sig + "\n"
                    # update/insert annotation
                    if annotation_pattern.match(content[i - 1]):
                        content[i - 1] = annotation
                    else:
                        content.insert(i, annotation)
            with open(file_path, "w") as f:
                f.writelines(content)


if __name__ == "__main__":
    main()
