// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IVault.sol";
import "../svg/ISvgManager.sol";
import {Strategy, ERC20Strategy} from "./Strategy.sol";
import "../libraries/Utils.sol";
import 'base64-sol/base64.sol';

import "hardhat/console.sol";

contract Vault is ERC20, IVault, AccessControl {
    using Math for uint256;

    address private immutable _protocolTreasury;
    address private immutable _svgManager;
    IERC20Metadata private immutable _asset;
    uint8 private _decimals;
    
    // vault params
    string private _apy; // 임시 변수(추후 삭제 예정)
    uint256 private _currentPrice; // 임시 변수(추후 삭제 예정) // dollar 기준(decimal : 18)
    string private _color;
    string public _dacName;
    uint256 public _sinceDate;

    bytes32 public constant DAC_ROLE = keccak256("DAC_ROLE"); // strategy team
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE"); // router에서만 호출 가능

    /// @notice 특정한 ERC20 token을 asset으로 받는 새로운 vault를 생성.
    /// @param params vaultName/vaultSymbol/dacName/color/apy(apy는 그냥 임시로 param 넣어주는 것)
    /// @param asset_ asset으로 받을 ERC20 토큰.
    /// @param caller_ vault를 생성하고자 하는 유저. role의 admin이 되어 DAC 멤버들을 추가하거나 삭제할 수 있다.
    /// @param router_ vault와 소통할 수 있는 router.
    constructor(
        string[] memory params,
        IERC20Metadata asset_, 
        address caller_,
        address router_,
        address protocolTreasury_,
        address svgManager_)
        ERC20(
            params[0],
            params[1]
        )
    {
        // vault params
        _dacName = params[2];
        _color = params[3];
        _apy = params[4];
        _sinceDate = block.timestamp;

        // vault setting
        _asset = asset_;
        _decimals = asset_.decimals();
        _protocolTreasury = protocolTreasury_;
        _svgManager = svgManager_;
        performanceFeePercent = 15e16; // 기본 fee 세팅 : 15%

        // current price(임시)
        _currentPrice = 10**decimals(); 

        _grantRole(DEFAULT_ADMIN_ROLE, caller_);
        _setupRole(DAC_ROLE, caller_); // 나중에 caller_가 다른 DAC 멤버를 추가할 수 있음
        _setupRole(ROUTER_ROLE, router_);
    }

    function isAdmin(address user) public view override returns(bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, user);
    }

    function isDAC(address user) public view override returns(bool) {
        return hasRole(DAC_ROLE, user);
    }
    
    function setCurrentPrice(uint256 newCurrentPrice) public override {
        _currentPrice = newCurrentPrice * (10**decimals());
    }

    function getCurrentPrice() public view override returns(uint256) {
        return _currentPrice;
    }

    /// @notice 이 vault contract의 decimal을 반환.
    /// @dev asset의 deciamal과 동일하게 overriding.
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) { // _asset의 decimal과 같이 통일시킴
        return _decimals;
    }

    /// @notice strategy에서 모든 underlying 회수, deposit 불가능
    bool emergencyExit = false; // true면 emergency exit 진행

    event EmergencyUpdated(address user, bool isEmergency);

    function setEmergencyExit(bool isEmergency) external override onlyRole(DAC_ROLE){
        require(isEmergency != emergencyExit, "Vault: Already Set Emergency Shutdown");
        emergencyExit = isEmergency;
        strategy.setEmergency(isEmergency);

        if(isEmergency){ // emergency 상태임
            strategy = Strategy(address(0));
        }

        emit EmergencyUpdated(_msgSender(), isEmergency);
    }

    /// @notice DAC들이 가져가는 performance fee. 단위는 %
    uint256 public performanceFeePercent;

    event PerformanceFeePercentUpdated(address indexed user, uint256 newPerformanceFeePercent);

    function setPerformanceFeePercent(uint256 newPerformanceFeePercent) external override onlyRole(DAC_ROLE) {
        require(newPerformanceFeePercent <= 1e18, "Vault: Fee too high");
        performanceFeePercent = newPerformanceFeePercent;
        emit PerformanceFeePercentUpdated(_msgSender(), newPerformanceFeePercent);
    }

    /// @notice harvest와 harvest 사이의 delay를 지정. 만약 nextHarvest가 0이라면 계속 똑같은 harvestDelay를 유지.
    /// vault 당 strategy가 1개라고 가정했기 때문에, harvest 기간 동안 harvest 역시 1번만 일어남
    /// (=> window가 의미가 없다고 생각해 삭제함)
    uint256 public harvestDelay;
    uint256 public nextHarvestDelay;

    event HarvestDelayUpdated(address indexed user, uint256 newHarvestDelay);
    event NextHarvestDelayUpdated(address indexed user, uint256 newNextHarvestDelay);

    function setHarvestDelay(uint256 newHarvestDelay) external override onlyRole(DAC_ROLE) {
        require(newHarvestDelay >= 6 hours, "Vault: Delay too short");
        require(newHarvestDelay <= 365 days, "Vault: Delay too long");
        if(harvestDelay == 0){
            harvestDelay = newHarvestDelay;
            emit HarvestDelayUpdated(_msgSender(), newHarvestDelay);
        }
        else {
            nextHarvestDelay = newHarvestDelay;
            emit HarvestDelayUpdated(_msgSender(), newHarvestDelay);
        }

    }
    
    /// @notice vault가 갖고 있는 _asset의 비중. 1e18이 100%를 의미.
    uint256 public targetFloatPercent; 
    event targetFloatPercentUpdated(address indexed user, uint256 newTargetFloatPercent);

    function setTargetFloatPercent(uint256 newTargetFloatPercent) external override onlyRole(DAC_ROLE) {
        require(newTargetFloatPercent <= 1e18, "Vault: Target float percent too high");
        targetFloatPercent = newTargetFloatPercent;
        emit targetFloatPercentUpdated(_msgSender(), newTargetFloatPercent);
    }

    /// @notice strategy가 갖고 있는 _asset의 양.
    /// 이때, quinoa는 하나의 vault 당 하나의 strategy만이 있다고 가정.
    /// lockedProfit 포함
    uint256 public strategyDebt; 
    /// @notice 이 vault에서 사용하는 strategy. 
    Strategy public strategy;

    event StrategyUpdated(address indexed user, Strategy newStrategy);

    function setStrategy(Strategy newStrategy) external override onlyRole(DAC_ROLE) {
        // strategy는 딱 하나만 설정할 수 있음
        require(address(strategy) == address(0), "Vault: Already set strategy");
        strategy = newStrategy;
        emit StrategyUpdated(_msgSender(), newStrategy);
    }

    /// @notice 제일 최근에 진행된 harvest. harvest는 딱 한번만 실행되며, strategy는 1개로 고정되어 있음.
    uint64 public lastHarvest;
    /// @notice 마지막 harvest에서의 locked profit 양. delay 기간에 천천히 풀림.
    uint256 public maxLockedProfit; 
    
    event Harvest(address indexed user, Strategy strategy);

    /// @notice harvest를 진행. strategy에서 얻은 수익들이 실제 수익이라고 인정됨.
    function harvest() external override onlyRole(DAC_ROLE) {
        require(!emergencyExit, "Vault: It is Emergency Situation");
        if(block.timestamp >= lastHarvest + harvestDelay) {
            lastHarvest = uint64(block.timestamp); 
        }
        else {
            require(block.timestamp <= lastHarvest + harvestDelay, "Vault: Bad harvest time");
        }

        uint256 oldStrategyDebt = strategyDebt;
        strategyDebt = strategy.balanceOfUnderlying(address(this));
        uint256 totalProfitAccured = strategyDebt - oldStrategyDebt;

        // fee -> 일단 이 vault contract에 share 저장.
        uint256 feesAccured = totalProfitAccured.mulDiv(performanceFeePercent, 1e18, Math.Rounding.Down);
        uint256 forDAC = feesAccured.mulDiv(1, 2, Math.Rounding.Down);
        uint256 forTreasury = feesAccured - forDAC;

        _mint(address(this), forDAC.mulDiv(10**decimals(), convertToAssets(10**decimals()), Math.Rounding.Down));
        SafeERC20.safeTransfer(_asset, _protocolTreasury, forTreasury);

        maxLockedProfit = (calculateLockedProfit() + totalProfitAccured - feesAccured);
        
        lastHarvest = uint64(block.timestamp);

        emit Harvest(_msgSender(), strategy);

        uint256 newHarvestDelay = nextHarvestDelay;
        if(newHarvestDelay != 0) {
            harvestDelay  = newHarvestDelay;
            nextHarvestDelay = 0;
            emit HarvestDelayUpdated(_msgSender(), newHarvestDelay);
        }
    }

    event FeesClaimed(address indexed user, uint256 rvTokenAmount);

    /// @notice DAC는 자신의 fee(qvToken)를 claim할 수 있음.
    function claimFees(uint256 qvTokenAmount) external override onlyRole(ROUTER_ROLE) {
        emit FeesClaimed(_msgSender(), qvTokenAmount);
        SafeERC20.safeTransfer(this, _msgSender(), qvTokenAmount);
    }

    event StrategyDeposit(address indexed user, Strategy indexed strategy, uint256 assetAmount);
    event StrategyWithdrawal(address indexed user, Strategy indexed strategy, uint256 assetAmount);

    /// @notice assetAmount만큼 strategy로 deposit.
    /// 외부에서 호출 가능한 함수로, DAC만이 이를 호출 가능.
    function depositIntoStrategy(uint256 assetAmount) external override onlyRole(DAC_ROLE) {
        _depositIntoStrategy(assetAmount);
    }

    /// @dev assetAmount만큼 strategy로 deposit.
    /// internal 함수로, 실질적으로 deposit(실제로는 approve)이 이뤄짐.
    function _depositIntoStrategy(uint256 assetAmount) internal {
        strategyDebt += assetAmount;
        
        emit StrategyDeposit(_msgSender(), strategy, assetAmount);
        SafeERC20.safeApprove(_asset, address(strategy), assetAmount);
        require(ERC20Strategy(address(strategy)).mint(assetAmount) == 0, "Vault: Deposit into strategy failed");
    }

    /// @notice assetAmount만큼 strategy에서 withdraw.
    function withdrawFromStrategy(uint256 assetAmount) external override onlyRole(DAC_ROLE) {
        _withdrawFromStrategy(assetAmount);
    }

    /// @dev assetAmount만큼 strategy에서 withdraw.
    function _withdrawFromStrategy(uint256 assetAmount) internal {
        require(assetAmount <= strategyDebt, "Vault: Too much amount");
        strategyDebt -= assetAmount;
        
        emit StrategyWithdrawal(_msgSender(), strategy, assetAmount);
        require(strategy.redeemUnderlying(assetAmount)==0, "Vault: Withdraw into strategy failed");
    }

    /// @notice 현재 vault의 asset이 무엇인지 반환.
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice 현재 vault의 float 즉, 현재 vault가 실제로 보유하고 있는 asset의 양을 반환.
    function totalFloat() public view override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @notice 현재 vault가 운용하고 있는 asset의 양으로 locked profit 포함.
    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + strategyDebt;
    }
    
    /// @notice 현재 vault에서 출금할 수 있는 asset의 양으로, locked profit은 미포함.
    function totalFreeFund() public view override returns (uint256) {
        return totalAssets() - calculateLockedProfit();
    }

    /// @notice 현재 시점에서의 locked profit이 얼마나 되는지 계산.
    /// harvest delay동안 locked profit이 풀리게 되므로, 남은 delay 시간에 비례해서 locked profit을 계산함.
    function calculateLockedProfit() public view override returns (uint256) {
        uint256 previousHarvest = lastHarvest;
        uint256 harvestInterval = harvestDelay;

        // If the harvest delay has passed, there is no locked profit.
        if(block.timestamp >= previousHarvest + harvestInterval) return 0;

        uint256 maximumLockedProfit = maxLockedProfit;
        return maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousHarvest)) / harvestInterval;
    }

    /// @notice assets 만큼의 asset 양이 얼만큼의 shares(qv token)에 해당하는지 계산
    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /// @notice shares 만큼의 qv token 양이 얼만큼의 assets에 해당하는지 계산
    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }
    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Down);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Down);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    function deposit(uint256 assets, address receiver) public override onlyRole(ROUTER_ROLE) returns (uint256) {
        require(!emergencyExit, "Vault: It is Emergency Situation");
        require(assets + totalAssets() <= maxDeposit(receiver), "Vault: deposit more than max");
        uint256 shares = previewDeposit(assets);
        require(shares > 0, "Vault: deposit less than minimum");
        _deposit(_msgSender(), receiver, assets, shares); // _msgSender는 router
        return shares;
    }

    function mint(uint256 shares, address receiver) public override onlyRole(ROUTER_ROLE) returns (uint256) {
        require(shares + totalSupply() <= maxMint(receiver), "Vault: mint more than max");
        uint256 assets = previewMint(shares);
        require(assets > 0, "Vault: mint less than minimum");
        _deposit(_msgSender(), receiver, assets, shares);
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver, // receiver는 router가 되는 것
        address owner // owner는 share를 가지고 있는 사람. 이것도 router
    ) public override onlyRole(ROUTER_ROLE) returns (uint256) {
        require(assets <= maxWithdraw(owner), "Vault: withdraw more than max");
        // float 채워 넣기
        uint256 shares = previewWithdraw(assets);
        require(shares > 0, "Vault: withdraw less than minimum");
        _fillFloat(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares); // caller와 owner가 다른 경우도 있음
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver, // router
        address owner // router
    ) public override onlyRole(ROUTER_ROLE) returns (uint256) {
        require(shares <= maxRedeem(owner), "Vault: redeem more than max");
        uint256 assets = previewRedeem(shares);
        require(assets > 0, "Vault: redeem less than minimum");
        _fillFloat(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return assets;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        return (assets == 0 || supply == 0)
            ? assets.mulDiv(10**decimals(), 10**_asset.decimals(), rounding)
            : assets.mulDiv(supply, totalFreeFund(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256 assets) {
        uint256 supply = totalSupply();
        return
            (supply == 0)
                ? shares.mulDiv(10**_asset.decimals(), 10**decimals(), rounding) // return x * y / z;
                : shares.mulDiv(totalFreeFund(), supply, rounding);
    }

    // _deposit(_msgSender(), receiver, assets, shares);
    // caller의 asset을 vault로 deposit하고, receiver에게 share 만큼을 minting 해주면 됨
    function _deposit(
        address caller, // router
        address receiver, // router
        uint256 assets, 
        uint256 shares
    ) internal {
        SafeERC20.safeTransferFrom(_asset, caller, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller, // router
        address receiver, 
        address owner, // router
        uint256 assets, // router
        uint256 shares
    ) internal {
        // caller가 share의 owner가 아닌 경우는, caller가 owner의 spender인 경우임
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        // 현재 vault에 있는 asset을 transfer
        SafeERC20.safeTransfer(_asset, receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev vault에서 withdraw나 redeem 전에 float이 부족할 것 같으면 float을 충당할 수 있을 만큼의 양을 strategy에서 withdraw
    function _fillFloat(uint256 assets) internal {
        uint256 float = totalFloat();
        if(assets > float) {
            // withdraw 이후에 필요한 float의 양
            uint256 amountForTargetFloat = (totalFreeFund() - assets).mulDiv(targetFloatPercent, 1, Math.Rounding.Down);
            // 현재 float에 대해서, withdraw를 하려면 얼마나 더 asset 필요한지
            uint256 amountForWithdrawal = assets - float;

            _withdrawFromStrategy(amountForTargetFloat + amountForWithdrawal);
        }
    }

    //vault 정보 넣어서 만든 완성된 svg
    function vaultInfoSvg() 
    public
    view
    returns(string memory) 
    {   
        uint256 totalVolume = _currentPrice.mulDiv(totalAssets(), 10**decimals(), Math.Rounding.Down);
        string memory _vaultVolume = Utils.volumeToString(totalVolume);
        (uint year, uint month, uint day) = Utils.timestampToDate(_sinceDate);
        string memory _vaultDate = string(abi.encodePacked(Strings.toString(year), '.', Strings.toString(month), '.', Strings.toString(day)));        
        string memory _vaultAddr = Strings.toHexString(uint256(uint160(address(this))), 20);
        
        string memory svg = ISvgManager(_svgManager).generateNftSvg(
            ISvgManager.SvgParams(
            _color, // #FFCCCC 형식
            name(),
            _vaultAddr,
            _vaultDate,
            _apy,
            _vaultVolume,
            _dacName,
            "   --",
            "   --"
        ));
        return svg;
    }

    function vaultSvgUri()
    public
    view
    override
    returns(string memory){
        string memory nftImage = Base64.encode(bytes(vaultInfoSvg()));

        return string(abi.encodePacked(
            'data:image/svg+xml;base64,',
            nftImage
        ));
    }

    function vaultInfo() external view override returns(string[8] memory){
        uint256 totalVolume = _currentPrice.mulDiv(totalAssets(), 10**decimals(), Math.Rounding.Down);
        string memory _vaultVolume = Utils.volumeToString(totalVolume);
        (uint year, uint month, uint day) = Utils.timestampToDate(_sinceDate);
        string memory _vaultDate = string(abi.encodePacked(Strings.toString(year), '.', Strings.toString(month), '.', Strings.toString(day)));        
        string memory _vaultAddr = Strings.toHexString(uint256(uint160(address(this))), 20);
        
        return [_color, name(), _asset.symbol(), _vaultAddr, _vaultDate, _apy, _vaultVolume, _dacName];
    }
} 