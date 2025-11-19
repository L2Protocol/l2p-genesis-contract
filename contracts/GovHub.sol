pragma solidity 0.6.4;

import "./System.sol";
import "./interface/0.6.x/IParamSubscriber.sol";

contract GovHub is System {
    uint32 public constant ERROR_TARGET_NOT_CONTRACT = 101;
    uint32 public constant ERROR_TARGET_CONTRACT_FAIL = 102;

    event failReasonWithStr(string message);
    event failReasonWithBytes(bytes message);
    event paramChange(string key, bytes value);  // @dev deprecated

    struct ParamChangePackage {
        string key;
        bytes value;
        address target;
    }

    function updateParam(string calldata key, bytes calldata value, address target) external onlyGovernorTimelock {
        ParamChangePackage memory proposal = ParamChangePackage(key, value, target);
        notifyUpdates(proposal);
    }

    function notifyUpdates(ParamChangePackage memory proposal) internal returns (uint32) {
        if (!isContract(proposal.target)) {
            emit failReasonWithStr("the target is not a contract");
            return ERROR_TARGET_NOT_CONTRACT;
        }
        try IParamSubscriber(proposal.target).updateParam(proposal.key, proposal.value) { }
        catch Error(string memory reason) {
            emit failReasonWithStr(reason);
            return ERROR_TARGET_CONTRACT_FAIL;
        } catch (bytes memory lowLevelData) {
            emit failReasonWithBytes(lowLevelData);
            return ERROR_TARGET_CONTRACT_FAIL;
        }
        return CODE_OK;
    }
}
