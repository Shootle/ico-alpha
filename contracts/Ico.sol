pragma solidity ^0.4.17;

import 'zeppelin-solidity/contracts/token/BasicToken.sol';

// NOTE: BasicToken only has partial ERC20 support
contract Ico is BasicToken {
  address owner;
  uint256 public teamNum;
  mapping(address => bool) team;

  // expose these for ERC20 tools
  string public constant name = "LUNA";
  string public constant symbol = "LUNA";
  uint8 public constant decimals = 18;

  // Significant digits tokenPrecision
  uint256 private constant tokenPrecision = 10e17;

  // TODO: set this final, this equates to an amount
  // in dollars.
  uint256 public constant hardCap = 17000 * tokenPrecision;

  // Tokens issued and frozen supply to date
  uint256 public tokensIssued = 0;
  uint256 public tokensFrozen = 0;

  // struct representing a dividends snapshot
  struct DividendSnapshot {
    uint256 tokensIssued;
    uint256 dividendsIssued;
    uint256 managementDividends;
  }
  // An array of all the DividendSnapshot so far
  DividendSnapshot[] dividendSnapshots;

  // Mapping of user to the index of the last dividend that was awarded to zhie
  mapping(address => uint256) lastDividend;

  // Management fees share express as 100/%: eg. 20% => 100/20 = 5
  uint256 public constant managementFees = 10;

  // Assets under management in USD
  uint256 private aum = 0;

  // number of tokens investors will receive per eth invested
  uint256 public tokensPerEth;

  // Ico start/end timestamps, between which (inclusively) investments are accepted
  uint public icoStart;
  uint public icoEnd;

  // drip percent in 100 / percentage
  uint256 public dripRate = 50;

  // custom events
  event Burn(address indexed from, uint256 value);
  event Participate(address indexed from, uint256 value);
  event ReconcileDividend(address indexed from, uint256 period, uint256 value);

  /**
   * ICO constructor
   * Define ICO details and contribution period
   */
  function Ico(uint256 _icoStart, uint256 _icoEnd, address[] _team, uint256 _tokensPerEth) public {
    // require (_icoStart >= now);
    require (_icoEnd >= _icoStart);
    require (_tokensPerEth > 0);

    owner = msg.sender;

    icoStart = _icoStart;
    icoEnd = _icoEnd;
    tokensPerEth = _tokensPerEth;

    // initialize the team mapping with true when part of the team
    teamNum = _team.length;
    for (uint256 i = 0; i < teamNum; i++) {
      team[_team[i]] = true;
    }
  }

  /**
   * Modifiers
   */
  modifier onlyOwner() {
    require (msg.sender == owner);
    _;
  }

  modifier onlyTeam() {
    require (team[msg.sender] == true);
    _;
  }

  /**
   *
   * Function allowing investors to participate in the ICO.
   * Specifying the beneficiary will change who will receive the tokens.
   * Fund tokens will be distributed based on amount of ETH sent by investor, and calculated
   * using tokensPerEth value.
   */
  function participate(address beneficiary) public payable {
    require (beneficiary != address(0));
    require (now >= icoStart && now <= icoEnd);
    require (msg.value > 0);

    uint256 ethAmount = msg.value;
    uint256 numTokens = ethAmount.mul(tokensPerEth);

    require(numTokens.add(tokensIssued) <= hardCap);

    balances[beneficiary] = balances[beneficiary].add(numTokens);
    tokensIssued = tokensIssued.add(numTokens);
    tokensFrozen = tokensIssued * 2;
    aum = tokensIssued;

    owner.transfer(ethAmount);
    // Our own custom event to monitor ICO participation
    Participate(beneficiary, numTokens);

    // Let ERC20 tools know of token hodlers
    Transfer(0x0, beneficiary, numTokens);
  }

  /**
   *
   * We fallback to the partcipate function
   */
  function () external payable {
     participate(msg.sender);
  }

  /**
   * Internal burn function, only callable by team
   *
   * @param _amount is the amount of tokens to burn.
   */
  function burn(uint256 _amount) public onlyTeam returns (bool) {
    require(_amount <= balances[msg.sender]);

    // SafeMath.sub will throw if there is not enough balance.
    balances[msg.sender] = balances[msg.sender].sub(_amount);
    tokensIssued = tokensIssued.sub(_amount);

    uint256 tokenValue = aum.mul(tokenPrecision).div(tokensIssued);
    aum = aum.sub(tokenValue.mul(_amount));

    Burn(msg.sender, _amount);
    return true;
  }

  /**
   * Calculate the divends for the current period given the AUM profit
   *
   * @param totalProfit is the amount of total profit in USD.
   */
  function reportProfit(int256 totalProfit, address saleAddress) public onlyTeam returns (bool) {
    // first we new dividends if this period was profitable
    if (totalProfit > 0) {
      // We only care about 50% of this, as the rest is reinvested right away
      uint256 profit = uint256(totalProfit).mul(tokenPrecision).div(2);

      // this will throw if there are not enough tokens
      addNewDividends(profit);
    }

    // then we drip
    drip(saleAddress);
    // adjust AUM
    aum = aum.add(uint256(totalProfit).mul(tokenPrecision));

    return true;
  }


  function drip(address saleAddress) internal {
    uint256 dripTokens = tokensFrozen.div(dripRate);

    tokensFrozen = tokensFrozen.sub(dripTokens);
    tokensIssued = tokensIssued.add(dripTokens);
    reconcileDividend(saleAddress);
    balances[saleAddress] = balances[saleAddress].add(dripTokens);
  }

  /**
   * Calculate the divends for the current period given the dividend
   * amounts (USD * tokenPrecision).
   */
  function addNewDividends(uint256 profit) internal {
    uint256 newAum = aum.add(profit); // 18 sig digits
    uint256 newTokenValue = newAum.mul(tokenPrecision).div(tokensIssued); // 18 sig digits
    uint256 totalDividends = profit.mul(tokenPrecision).div(newTokenValue); // 18 sig digits
    uint256 managementDividends = totalDividends.div(managementFees); // 17 sig digits
    uint256 dividendsIssued = totalDividends.sub(managementDividends); // 18 sig digits

    // make sure we have enough in the frozen fund
    require(tokensFrozen >= totalDividends);

    dividendSnapshots.push(DividendSnapshot(tokensIssued, dividendsIssued, managementDividends));

    // add the previous amount of given dividends to the tokensIssued
    tokensIssued = tokensIssued.add(totalDividends);
    tokensFrozen = tokensFrozen.sub(totalDividends);
  }

  /**
   * Withdraw all funds and kill fund smart contract
   */
  function liquidate() public onlyOwner returns (bool) {
    selfdestruct(owner);
  }


  // getter to retrieve divident owed
  function getOwedDividend(address _owner, bool emit) public view returns (uint256 dividend) {
    // And the address' current balance
    uint256 balance = BasicToken.balanceOf(_owner);
    // retrieve index of last dividend this address received
    // NOTE: the default return value of a mapping is 0 in this case
    uint idx = lastDividend[_owner];
    if (idx == dividendSnapshots.length) return 0;
    if (balance == 0 && team[_owner] != true) return 0;

    uint256 currBalance = balance;
    for (uint i = idx; i < dividendSnapshots.length; i++) {
      // We should be able to remove the .mul(tokenPrecision) and .div(tokenPrecision) and apply them once
      // at the beginning and once at the end, but we need to math it out
      dividend += currBalance.mul(tokenPrecision).div(dividendSnapshots[i].tokensIssued).mul(dividendSnapshots[i].dividendsIssued).div(tokenPrecision);

      // Add the management dividends in equal parts if the current address is part of the team
      if (team[_owner] == true) {
        dividend += dividendSnapshots[i].managementDividends.div(teamNum);
      }

      // If we can emit, broadcast ReconcileDividend event
      if (emit == true) {
        ReconcileDividend(_owner, i, dividend);
      }

      currBalance = balance + dividend;
    }

    return dividend;
  }

  // monkey patches
  function balanceOf(address _owner) public view returns (uint256) {
    return BasicToken.balanceOf(_owner).add(getOwedDividend(_owner, false));
  }


  // Reconcile all outstanding dividends for an address
  // into it's balance.
  function reconcileDividend(address _owner) internal {
    uint256 owedDividend = getOwedDividend(_owner, true);

    if(owedDividend > 0) {
      balances[_owner] = balances[_owner].add(owedDividend);
    }

    // register this user as being owed no further dividends
    lastDividend[_owner] = dividendSnapshots.length;
  }

  function transfer(address _to, uint256 _amount) public returns (bool) {
    reconcileDividend(msg.sender);
    reconcileDividend(_to);
    return BasicToken.transfer(_to, _amount);
  }

}
