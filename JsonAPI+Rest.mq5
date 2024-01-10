//+------------------------------------------------------------------+
//
// Copyright (C) 2019 Nikolai Khramkov
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
//+------------------------------------------------------------------+

// TODO: Deviation

#property copyright   "Copyright 2019, Nikolai Khramkov."
#property link        "https://github.com/khramkov"
#property version     "2.00"
#property description "MQL5 JSON API"
#property description "See github link for documentation" 

#include <Trade/AccountInfo.mqh>
#include <Trade/DealInfo.mqh>
#include <Trade/Trade.mqh>
#include <Zmq/Zmq.mqh>
#include <Json.mqh>

input string HOST="*";
input int SYS_PORT=2201;
input int DATA_PORT=2202;
input int LIVE_PORT=2203;

#include <RestApi.mqh>

input int      port = 6542;
input string   callbackUrl = "http://localhost/callback";
input string   callbackFormat = "json";
input string   url_swagger = "localhost:6542";
input int      CommandPingMilliseconds = 10;
input string   AuthToken = "{test-token}";
CRestApi api;

// ZeroMQ Cnnections
Context context("MQL5 JSON API");
Context context("MQL5 JSON API");
Socket *sysSocket = new Socket(context,ZMQ_REP);
Socket *dataSocket = new Socket(context,ZMQ_PUSH);
Socket *liveSocket = new Socket(context,ZMQ_PUSH);

// Global variables
bool debug = false;
bool liveStream = true;
bool connectedFlag= true;
int deInitReason = -1;
string chartSymbols[];
int chartSymbolCount = 0;
string chartSymbolSettings[][3];

//+------------------------------------------------------------------+
//| Bind ZMQ sockets to ports                                        |
//+------------------------------------------------------------------+
bool BindSockets(){
  bool result = false;
  result = sysSocket.bind(StringFormat("tcp://%s:%d", HOST,SYS_PORT));
  if (result == false) return result;
  result = dataSocket.bind(StringFormat("tcp://%s:%d", HOST,DATA_PORT));
  if (result == false) return result;
  result = liveSocket.bind(StringFormat("tcp://%s:%d", HOST,LIVE_PORT));
  if (result == false) return result;
  
  Print("Bound 'System' socket on port ", SYS_PORT);
  Print("Bound 'Data' socket on port ", DATA_PORT);
  Print("Bound 'Live' socket on port ", LIVE_PORT);
    
  sysSocket.setLinger(1000);
  dataSocket.setLinger(1000);
  liveSocket.setLinger(1000);
    
  // Number of messages to buffer in RAM.
  sysSocket.setSendHighWaterMark(1);
  dataSocket.setSendHighWaterMark(5);
  liveSocket.setSendHighWaterMark(1);

  return result;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit(){
  /* Bindinig ZMQ ports on init */
  int totalSymbols = SymbolsTotal(true);
  
  for(int k=0;k<totalSymbols;k++)
        {

            MqlBookInfo priceArray[];
            MarketBookAdd(SymbolName(k,true));
            bool getBook=MarketBookGet(SymbolName(k,true),priceArray);
        }
         
   api.Init("http://localhost", port, 1, url_swagger);
   api.SetCallback( callbackUrl, callbackFormat );
   api.SetAuth( AuthToken );
  // Skip reloading of the EA script when the reason to reload is a chart timeframe change
  if (deInitReason != REASON_CHARTCHANGE){
  
    EventSetMillisecondTimer(1);

    int bindSocketsDelay = 65; // Seconds to wait if binding of sockets fails.
    int bindAttemtps = 2; // Number of binding attemtps 
   
    Print("Binding sockets...");
   
    for(int i=0;i<bindAttemtps;i++){
      if (BindSockets()) return(INIT_SUCCEEDED);
      else {
         Print("Binding sockets failed. Waiting ", bindSocketsDelay, " seconds to try again...");
         Sleep(bindSocketsDelay*1000);
      }     
    }
    
    Print("Binding of sockets failed permanently.");
    return(INIT_FAILED);
  }

  return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason){
  /* Unbinding ZMQ ports on denit */

  // TODO Ports do not get freed immediately under Wine. How to properly close ports? There is a timeout of about 60 sec.
  // https://forum.winehq.org/viewtopic.php?t=22758
  // https://github.com/zeromq/cppzmq/issues/139
  
  deInitReason = reason;
  
  // Skip reloading of the EA script when the reason to reload is a chart timeframe change
  if (reason != REASON_CHARTCHANGE){
      Print(__FUNCTION__," Deinitialization reason: ", getUninitReasonText(reason));
      
      Print("Unbinding 'System' socket on port ", SYS_PORT,"..");
      sysSocket.unbind(StringFormat("tcp://%s:%d", HOST,SYS_PORT));
      Print("Unbinding 'Data' socket on port ", DATA_PORT,"..");
      dataSocket.unbind(StringFormat("tcp://%s:%d", HOST,DATA_PORT));
      Print("Unbinding 'Live' socket on port ", LIVE_PORT, "..");
      liveSocket.unbind(StringFormat("tcp://%s:%d", HOST,LIVE_PORT));
      delete sysSocket;
      delete dataSocket;
      delete liveSocket;
   
      // Shutdown ZeroMQ Context
      context.shutdown();
      context.destroy(0);
      
      EventKillTimer();
  }
}

/*
void OnTick(){
 
}
*/

//+------------------------------------------------------------------+
//| Check if subscribed to symbol and timeframe combination                                 |
//+------------------------------------------------------------------+
bool hasChartSymbol(string symbol, string chartTF)
  {
     for(int i=0;i<ArraySize(chartSymbols);i++)
     {
      if(chartSymbolSettings[i][0] == symbol && chartSymbolSettings[i][1] == chartTF ){
          return true;
      }
     }
     return false;
  }

//+------------------------------------------------------------------+
//| Stream live price data                                          |
//+------------------------------------------------------------------+
void StreamPriceData(){
  // If liveStream == true, push last candle to liveSocket. 
  if(liveStream){
    CJAVal last;
    if(TerminalInfoInteger(TERMINAL_CONNECTED)){
   
      connectedFlag=true; 

      
      for(int i=0;i<chartSymbolCount;i++){
        string symbol=chartSymbolSettings[i][0];
        string chartTF=chartSymbolSettings[i][1];
        datetime lastBar=chartSymbolSettings[i][2];
         
        
        CJAVal Data;
        ENUM_TIMEFRAMES period = GetTimeframe(chartTF);
        
        datetime thisBar = 0;
        MqlTick tick;
        MqlRates rates[1];
        
        if( chartTF == "TICK"){
          if(SymbolInfoTick(symbol,tick) !=true) { /*error processing */ };
          thisBar=(datetime) tick.time_msc;
        }
        else {
          if(CopyRates(symbol,period,1,1,rates)!=1) { /*error processing */ };
          thisBar=(datetime)rates[0].time;
        }
        
        if(lastBar!=thisBar){
          if(lastBar!=0){ // skip first price data after startup/reset
        
            if( chartTF == "TICK"){
              Data[0] = (long)    tick.time_msc;
              Data[1] = (double)  tick.bid;
              Data[2] = (double)  tick.ask;
            }
            else {;
              Data[0] = (long) rates[0].time;
              Data[1] = (double) rates[0].open;
              Data[2] = (double) rates[0].high;
              Data[3] = (double) rates[0].low;
              Data[4] = (double) rates[0].close;
              Data[5] = (double) rates[0].tick_volume;
            }
  
            last["status"] = (string) "CONNECTED";
            last["symbol"] = (string) symbol;
            last["timeframe"] = (string) chartTF;
            last["data"].Set(Data);
              
            string t=last.Serialize();
            if(debug) Print(t);
            Print(t);
            InformClientSocket(liveSocket,t);
            chartSymbolSettings[i][2]=thisBar;
  
          }
          else chartSymbolSettings[i][2]=thisBar;
        }
      }
    }
    else {
      // send disconnect message only once
      if(connectedFlag){
        last["status"] = (string) "DISCONNECTED";
        string t=last.Serialize();
        if(debug) Print(t);
        InformClientSocket(liveSocket,t);
        connectedFlag=false;
      }
    }
  }
  // return true;
}

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer(){

  ZmqMsg request;
   
  StreamPriceData();
  
  // Get request from client via System socket.
  sysSocket.recv(request,true);
  
  api.Processing();
  
  // Request recived
  if(request.size()>0){ 
    // Pull request to RequestHandler().
    RequestHandler(request);
  }

}

//+------------------------------------------------------------------+
//| ChartEvent function                                              |
//| This function must be declared, even if it empty.                |
//+------------------------------------------------------------------+

void OnChartEvent(const int id,         // event id
                  const long& lparam,   // event param of long type
                  const double& dparam, // event param of double type
                  const string& sparam) // event param of string type

  {
   //--- Add your code here...
  }

//+------------------------------------------------------------------+
//| Request handler                                                  |
//+------------------------------------------------------------------+
void RequestHandler(ZmqMsg &request){

  CJAVal message;
        
  ResetLastError();
  // Get data from reguest
  string msg=request.getData();
  
 Print("Processing:"+msg);
  
  // Deserialize msg to CJAVal array
  if(!message.Deserialize(msg)){
    ActionDoneOrError(65537, __FUNCTION__);
    Alert("Deserialization Error");
    ExpertRemove();
  }
  // Send response to System socket that request was received
  // Some historical data requests can take a lot of time
  InformClientSocket(sysSocket, "OK");
  
  // Process action command
  string action = message["action"].ToStr();
  
  if(action=="CONFIG")          {ScriptConfiguration(message);}
  else if(action=="ACCOUNT")    {GetAccountInfo();}
  else if(action=="MARKETDEPTH")    {GetMarketBookDepth();}
  else if(action=="SENDNOTIF")    {SendNotif(message);}
  else if(action=="WATCHLIST")    {GetWatchList();}
  else if(action=="GETPREVHIGHLOWTODAYOPEN")    {GetPrevHighLowTodayOpen(message);}
  else if(action=="LIVESYMBOLS") {GetLiveStreamSymbols();}
  else if(action=="BALANCE")    {GetBalanceInfo();}
  else if(action=="HISTORY")    {HistoryInfo(message);}
  else if(action=="TRADE")      {TradingModule(message);}
  else if(action=="POSITIONS")  {GetPositions(message);}
  else if(action=="ORDERS")     {GetOrders(message);}
  else if(action=="WEEKLYOPEN") {GetWeeklyOpen(message);}
  else if(action=="RESET")      {ResetSubscriptions(message);}
  // Action command error processing
  else ActionDoneOrError(65538, __FUNCTION__);
   
}
  
//+------------------------------------------------------------------+
//| Reconfigure the script params                                    |
//+------------------------------------------------------------------+
void ScriptConfiguration(CJAVal &dataObject){
  
  string symbol=dataObject["symbol"].ToStr();
  string chartTF=dataObject["chartTF"].ToStr();
  string actionType=dataObject["actionType"].ToStr();

  string symbArr[1];
  symbArr[0]= symbol;
  
  if (!hasChartSymbol(symbol, chartTF)) {
    ArrayInsert(chartSymbols,symbArr,0);
    ArrayResize(chartSymbolSettings,chartSymbolCount+1);
    chartSymbolSettings[chartSymbolCount][0]=symbol;
    chartSymbolSettings[chartSymbolCount][1]=chartTF;
    // lastBar
    chartSymbolSettings[chartSymbolCount][2]=0; // to initialze with value 0 skips the first price 
    chartSymbolCount++;
  }
  
  if(SymbolInfoInteger(symbol, SYMBOL_EXIST)){  
    ActionDoneOrError(ERR_SUCCESS, __FUNCTION__);  
  }
  else ActionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);

}

//+------------------------------------------------------------------+
//| Account information                                              |
//+------------------------------------------------------------------+

void SendNotif(CJAVal &dataObject){

  CJAVal info;
  info["action"]="SENDNOTIF";
  info["result"]="Done";
  
  string textToSend = dataObject["comment"].ToStr();

  string t = info.Serialize();  
  InformClientSocket(dataSocket,t);
  
  SendNotification(textToSend);

}
void GetAccountInfo(){
  
  CJAVal info;
  
  info["error"] = false;
  info["broker"] = AccountInfoString(ACCOUNT_COMPANY);
  info["currency"] = AccountInfoString(ACCOUNT_CURRENCY);
  info["server"] = AccountInfoString(ACCOUNT_SERVER); 
  info["trading_allowed"] = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
  info["bot_trading"] = AccountInfoInteger(ACCOUNT_TRADE_EXPERT);   
  info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
  info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
  info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
  info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
  info["margin_level"] = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
  
  string t=info.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Balance information                                              |
//+------------------------------------------------------------------+
void GetBalanceInfo(){  
      
  CJAVal info;
  
  info["balance"] = AccountInfoDouble(ACCOUNT_BALANCE);
  info["equity"] = AccountInfoDouble(ACCOUNT_EQUITY);
  info["margin"] = AccountInfoDouble(ACCOUNT_MARGIN);
  info["margin_free"] = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
  

  
  string t=info.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}



//+------------------------------------------------------------------+
//| Previous Day High Low Open information                                              |
//+------------------------------------------------------------------+
void GetPrevHighLowTodayOpen(CJAVal &dataObject){  
      
  CJAVal info;
  string symbol=dataObject["symbol"].ToStr();
  
  
  MqlRates PriceDataTableDaily[];  
   CopyRates(symbol,PERIOD_D1,0,2,PriceDataTableDaily); 
  
  info["yesterdayHigh"] = PriceDataTableDaily[0].high;
  info["yesterdayLow"] = PriceDataTableDaily[0].low;
  info["todayOpen"] = PriceDataTableDaily[1].open;
  info["symbol"] = symbol;
  
  
  string t=info.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Get WeeklyOpen information                                              |
//+------------------------------------------------------------------+
void GetWeeklyOpen(CJAVal &dataObject){  
      
  CJAVal info;
  string symbol=dataObject["symbol"].ToStr();
  
  
  MqlRates PriceDataTableDaily[];  
   CopyRates(symbol,PERIOD_W1,0,2,PriceDataTableDaily); 
  
  info["weeklyOpen"] = PriceDataTableDaily[1].open;
  info["previousWeekHigh"] = PriceDataTableDaily[0].high;
  info["previousWeekLow"] = PriceDataTableDaily[0].low;
  info["symbol"] = symbol;
  
  
  string t=info.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}


//+------------------------------------------------------------------+
//| Watchlist symbols                                       |
//+------------------------------------------------------------------+
void GetWatchList(){

   CJAVal info;
  
  int totalSymbols = SymbolsTotal(true);
   for(int k=0;k<totalSymbols;k++)
        {
            string symbolName = SymbolInfoString(SymbolName(k,true),SYMBOL_ISIN);
            info.Add(symbolName);
        }
        
  string t=info.Serialize();
  
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);     
  
}



//+------------------------------------------------------------------+
//| LiveStream symbols                                       |
//+------------------------------------------------------------------+
void GetLiveStreamSymbols(){

   CJAVal data;
  
  int totalSymbols = ArraySize(chartSymbols);
   for(int k=0;k<totalSymbols;k++)
        {
            CJAVal info;
            string symbolName = chartSymbolSettings[k][0];
            string timeFrame = chartSymbolSettings[k][1];
            info["symbolName"]=(symbolName);
            info["timeFrame"]=(timeFrame);
            data["data"].Add(info);
        }
        
  string t=data.Serialize();
  
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);     
  
}





//+------------------------------------------------------------------+
//| MarketBookDepth information by watchlist                                             |
//+------------------------------------------------------------------+
void GetMarketBookDepth(){  
         
  CJAVal info;
  
  int totalSymbols = SymbolsTotal(true);
  
  
   for(int k=0;k<totalSymbols;k++)
        {
         MqlBookInfo priceArray[];
         MarketBookAdd(SymbolName(k,true));
         bool getBook=MarketBookGet(SymbolName(k,true),priceArray);
         getBook=MarketBookGet(SymbolName(k,true),priceArray);
         if(getBook)
           {
            int size=ArraySize(priceArray);
           
            for(int i=0;i<size;i++)
              {
              CJAVal depthInfo;
  
              depthInfo["price"]=priceArray[i].price;
              depthInfo["volume"]=priceArray[i].volume;
              if(priceArray[i].type==1){
              depthInfo["type"]="sell";
              }
               if(priceArray[i].type==2){
              depthInfo["type"]="buy";
              }
              info[SymbolInfoString(SymbolName(k,true),SYMBOL_ISIN)].Add(depthInfo);
              }
           }
         else
           {
            Print("Could not get contents of the symbol DOM ",SymbolName(k,true));
           }
      }
     
     

  
  string t=info.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Push historical data to ZMQ socket                               |
//+------------------------------------------------------------------+
bool PushHistoricalData(CJAVal &data){
  string t=data.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
  return true;
}

//+------------------------------------------------------------------+
//| Get historical data                                              |
//+------------------------------------------------------------------+
void HistoryInfo(CJAVal &dataObject){
 
  string actionType = dataObject["actionType"].ToStr();
  string chartTF = dataObject["chartTF"].ToStr();
  string symbol=dataObject["symbol"].ToStr();

  // Write CVS fle to local directory
  if(actionType=="WRITE" && chartTF=="TICK"){

    CJAVal data, d, msg;
    MqlTick tickArray[];
    string fileName=symbol + "-" + chartTF + ".csv";  // file name
    string directoryName="Data"; // directory name
    string outputFile=directoryName+"\\"+fileName;
   
    ENUM_TIMEFRAMES period=GetTimeframe(chartTF); 
    datetime fromDate=(datetime)dataObject["fromDate"].ToInt();
    datetime toDate=TimeCurrent();
    if(dataObject["toDate"].ToInt()!=NULL) toDate=(datetime)dataObject["toDate"].ToInt();

    Print("Fetching HISTORY");
    Print("1) Symbol: "+symbol);
    Print("2) Timeframe: Ticks");
    Print("3) Date from: "+TimeToString(fromDate));
    if(dataObject["toDate"].ToInt()!=NULL)Print("4) Date to:"+TimeToString(toDate));
    
    int tickCount = 0;
    ulong fromDateM = StringToTime(fromDate);
    ulong toDateM = StringToTime(toDate);
   
    tickCount=CopyTicksRange(symbol,tickArray,COPY_TICKS_ALL,1000*(ulong)fromDateM,1000*(ulong)toDateM);
    if(tickCount){  
      ActionDoneOrError(ERR_SUCCESS  , __FUNCTION__);  
    }
    else ActionDoneOrError(65541 , __FUNCTION__);
    
    Print("Preparing data of ", tickCount, " ticks for ", symbol);
    int file_handle=FileOpen(outputFile, FILE_WRITE | FILE_CSV);
    if(file_handle!=INVALID_HANDLE){
        msg["status"] = (string) "CONNECTED";
        msg["type"] = (string) "NORMAL";
        msg["data"] = (string) StringFormat("Writing to: %s\\%s", TerminalInfoString(TERMINAL_DATA_PATH), outputFile);
        if(liveStream) InformClientSocket(liveSocket, msg.Serialize());
      ActionDoneOrError(ERR_SUCCESS  , __FUNCTION__);  
      PrintFormat("%s file is available for writing",fileName);
      PrintFormat("File path: %s\\Files\\",TerminalInfoString(TERMINAL_DATA_PATH));
      //--- write the time and values of signals to the file
      for(int i=0;i<tickCount;i++){
        FileWrite(file_handle,tickArray[i].time_msc, ",", tickArray[i].bid, ",", tickArray[i].ask);
          msg["status"] = (string) "CONNECTED";
          msg["type"] = (string) "FLUSH";
          msg["data"] = (string) tickArray[i].time_msc;
        if(liveStream) InformClientSocket(liveSocket, msg.Serialize());
      }
      //--- close the file
      FileClose(file_handle);
      PrintFormat("Data is written, %s file is closed",fileName);
        msg["status"] = (string) "DISCONNECTED";
        msg["type"] = (string) "NORMAL";
        msg["data"] = (string) StringFormat("Writing to: %s\\%s", outputFile, " is finished");
      if(liveStream) InformClientSocket(liveSocket, msg.Serialize());

    }
    else{ 
      PrintFormat("Failed to open %s file, Error code = %d",fileName,GetLastError());
      ActionDoneOrError(65542 , __FUNCTION__);
    }
    connectedFlag=false;
  }
  
  // Write CVS fle to local directory
  else if(actionType=="WRITE" && chartTF!="TICK"){
  
    CJAVal c, d;
    MqlRates r[];
    string fileName=symbol + "-" + chartTF + ".csv";  // file name
    string directoryName="Data"; // directory name
    string outputFile=directoryName+"//"+fileName;
    
    int barCount;    
    ENUM_TIMEFRAMES period=GetTimeframe(chartTF); 
    datetime fromDate=(datetime)dataObject["fromDate"].ToInt();
    datetime toDate=TimeCurrent();
    if(dataObject["toDate"].ToInt()!=NULL) toDate=(datetime)dataObject["toDate"].ToInt();

    Print("Fetching HISTORY");
    Print("1) Symbol :"+symbol);
    Print("2) Timeframe :"+EnumToString(period));
    Print("3) Date from :"+TimeToString(fromDate));
    if(dataObject["toDate"].ToInt()!=NULL)Print("4) Date to:"+TimeToString(toDate));
    
    barCount=CopyRates(symbol,period,fromDate,toDate,r);
        
    if(barCount){  
      ActionDoneOrError(ERR_SUCCESS, __FUNCTION__);  
    }
    else ActionDoneOrError(65541, __FUNCTION__);
    
    Print("Preparing tick data of ", barCount, " ticks for ", symbol);
    int file_handle=FileOpen(outputFile, FILE_WRITE | FILE_CSV);
    if(file_handle!=INVALID_HANDLE){
      PrintFormat("%s file is available for writing",outputFile);
      PrintFormat("File path: %s\\Files\\",TerminalInfoString(TERMINAL_DATA_PATH));
      //--- write the time and values of signals to the file
      for(int i=0;i<barCount;i++)
         FileWrite(file_handle,r[i].time, ",", r[i].open, ",", r[i].high, ",", r[i].low, ",", r[i].close, ",", r[i].tick_volume);
      //--- close the file
      FileClose(file_handle);
      PrintFormat("Data is written, %s file is closed", outputFile);
    }
    else{ 
      PrintFormat("Failed to open %s file, Error code = %d",outputFile,GetLastError());
      ActionDoneOrError(65542 , __FUNCTION__);
    }
  }
   
  else if(actionType=="DATA" && chartTF=="TICK"){

    CJAVal data, d;
    MqlTick tickArray[];
   
    ENUM_TIMEFRAMES period=GetTimeframe(chartTF); 
    datetime fromDate=(datetime)dataObject["fromDate"].ToInt();
    datetime toDate=TimeCurrent();
    if(dataObject["toDate"].ToInt()!=NULL) toDate=(datetime)dataObject["toDate"].ToInt();

    if(debug){
      Print("Fetching HISTORY");
      Print("1) Symbol: "+symbol);
      Print("2) Timeframe: Ticks");
      Print("3) Date from: "+TimeToString(fromDate));
      if(dataObject["toDate"].ToInt()!=NULL)Print("4) Date to:"+TimeToString(toDate));
    }
    
    int tickCount = 0;
    ulong fromDateM = StringToTime(fromDate);
    ulong toDateM = StringToTime(toDate);
   
    tickCount=CopyTicksRange(symbol ,tickArray, COPY_TICKS_ALL, 1000*(ulong)fromDateM, 1000*(ulong)toDateM);
    Print("Preparing tick data of ", tickCount, " ticks for ", symbol);
    if(tickCount){
      for(int i=0;i<tickCount;i++){
          data[i][0]=(long)   tickArray[i].time_msc;
          data[i][1]=(double) tickArray[i].bid;
          data[i][2]=(double) tickArray[i].ask;
          i++;
      }
      d["data"].Set(data);
    } else {d["data"].Add(data);}
    Print("Finished preparing tick data");
    
    d["symbol"]=symbol;   
    d["timeframe"]=chartTF;

    PushHistoricalData(d);
  }
  
  else if(actionType=="DATA" && chartTF!="TICK"){
  
    CJAVal c, d;
    MqlRates r[];
    
    int barCount=0;    
    ENUM_TIMEFRAMES period=GetTimeframe(chartTF); 
    Print((datetime)dataObject["fromDate"].ToInt());
    datetime fromDate=(datetime)dataObject["fromDate"].ToInt();
    datetime toDate=TimeCurrent();
    
    if(dataObject["toDate"].ToInt()!=NULL) toDate=(datetime)dataObject["toDate"].ToInt();

    if(true){
      Print("Fetching HISTORY");
      Print("1) Symbol :"+symbol);
      Print("2) Timeframe :"+EnumToString(period));
      Print("3) Date from :"+TimeToString(fromDate));
      if(dataObject["toDate"].ToInt()!=NULL)Print("4) Date to:"+TimeToString(toDate));
    }
      
    barCount=CopyRates(symbol, period, fromDate, toDate, r);
    if(barCount){
      for(int i=0;i<barCount;i++){
        c[i][0]=(long)   r[i].time;
        c[i][1]=(double) r[i].open;
        c[i][2]=(double) r[i].high;
        c[i][3]=(double) r[i].low;
        c[i][4]=(double) r[i].close;
        c[i][5]=(double) r[i].tick_volume;
      }
      d["data"].Set(c);
    }
    else {d["data"].Add(c);}
 
    d["symbol"]=symbol;
    d["timeframe"]=chartTF;

    PushHistoricalData(d);
  }
  
  else if(actionType=="TRADES"){
    CDealInfo tradeInfo;
    CJAVal trades, data;
    
    if (HistorySelect(0,TimeCurrent())){ 
      // Get total deals in history
      int total = HistoryDealsTotal(); 
      ulong ticket; // deal ticket
      
      for (int i=0; i<total; i++){
        if ((ticket=HistoryDealGetTicket(i))>0) {
          tradeInfo.Ticket(ticket);
          data["ticket"]=(long) tradeInfo.Ticket();
          data["time"]=(long) tradeInfo.Time();
          data["price"]=(double) tradeInfo.Price();
          data["volume"]=(double) tradeInfo.Volume(); 
          data["symbol"]=(string) tradeInfo.Symbol();
          data["type"]=(string) tradeInfo.TypeDescription(); 
          data["entry"]=(long) tradeInfo.Entry();  
          data["profit"]=(double) tradeInfo.Profit();
          
          trades["trades"].Add(data);
        }
      }
    }
    else {trades["trades"].Add(data);}
    
    string t=trades.Serialize();
    if(debug) Print(t);
    InformClientSocket(dataSocket,t);
  }
  // Error wrong action type
  else ActionDoneOrError(65538, __FUNCTION__);
}

//+------------------------------------------------------------------+
//| Fetch positions information                                      |
//+------------------------------------------------------------------+
void GetPositions(CJAVal &dataObject){  
  CPositionInfo myposition;
  CJAVal data, position;

  // Get positions  
  int positionsTotal=PositionsTotal();
  // Create empty array if no positions
  if(!positionsTotal){
   data["positions"].Add(position);
  } 
  // Go through positions in a loop
  for(int i=0;i<positionsTotal;i++){
    ResetLastError();
    
    if(myposition.SelectByIndex(i)){
      myposition.SelectByIndex(i);
      
      position["id"]=PositionGetInteger(POSITION_IDENTIFIER);
      position["magic"]=PositionGetInteger(POSITION_MAGIC);
      position["symbol"]=PositionGetString(POSITION_SYMBOL);
      position["type"]=EnumToString(ENUM_POSITION_TYPE(PositionGetInteger(POSITION_TYPE)));
      position["time_setup"]=PositionGetInteger(POSITION_TIME);
      position["open"]=PositionGetDouble(POSITION_PRICE_OPEN);
      position["stoploss"]=PositionGetDouble(POSITION_SL);
      position["takeprofit"]=PositionGetDouble(POSITION_TP);
      position["volume"]=PositionGetDouble(POSITION_VOLUME);
      
    
      data["error"]=(bool) false;
      data["positions"].Add(position);
      data["server_time"]=((int)TimeCurrent());
      
    }
      // Error handling    
    else ActionDoneOrError(ERR_TRADE_POSITION_NOT_FOUND, __FUNCTION__);
  }
  
  string t=data.Serialize();
  if(true) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Fetch orders information                                         |
//+------------------------------------------------------------------+
void GetOrders(CJAVal &dataObject){
  ResetLastError();
  
  COrderInfo myorder;
  CJAVal data, order;
  
  // Get orders
  if (HistorySelect(0,TimeCurrent())){    
    int ordersTotal = OrdersTotal();
    // Create empty array if no orders
    if(!ordersTotal) {data["error"]=(bool) false; data["orders"].Add(order);}
    
    for(int i=0;i<ordersTotal;i++){
      if (myorder.Select(OrderGetTicket(i))){   
        order["id"]=(string) myorder.Ticket();
        order["magic"]=OrderGetInteger(ORDER_MAGIC); 
        order["symbol"]=OrderGetString(ORDER_SYMBOL);
        order["type"]=EnumToString(ENUM_ORDER_TYPE(OrderGetInteger(ORDER_TYPE)));
        order["time_setup"]=OrderGetInteger(ORDER_TIME_SETUP);
        order["open"]=OrderGetDouble(ORDER_PRICE_OPEN);
        order["stoploss"]=OrderGetDouble(ORDER_SL);
        order["takeprofit"]=OrderGetDouble(ORDER_TP);
        order["volume"]=OrderGetDouble(ORDER_VOLUME_INITIAL);
        
        data["error"]=(bool) false;
        data["orders"].Add(order);
      } 
      // Error handling   
      else ActionDoneOrError(ERR_TRADE_ORDER_NOT_FOUND,  __FUNCTION__);
    }
  }
    
  string t=data.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Clear symbol subscriptions                                       |
//+------------------------------------------------------------------+

void ResetSubscriptions(CJAVal &dataObject){

   ArrayFree(chartSymbols);
   chartSymbolCount=0;
   ArrayFree(chartSymbolSettings);
   
   if(ArraySize(chartSymbols)!=0 ||ArraySize(chartSymbolSettings)!=0){
   // TODO Implement propery error codes and descriptions
   ActionDoneOrError(65540,  __FUNCTION__);
   }
   else ActionDoneOrError(ERR_SUCCESS, __FUNCTION__);  
}
  
//+------------------------------------------------------------------+
//| Trading module                                                   |
//+------------------------------------------------------------------+
void TradingModule(CJAVal &dataObject){
  ResetLastError();
  CTrade trade;
  
  string   actionType = dataObject["actionType"].ToStr();
  string   symbol=dataObject["symbol"].ToStr();
  // Check if symbol is the same
 // if(!(symbol==_Symbol)) ActionDoneOrError(ERR_MARKET_UNKNOWN_SYMBOL, __FUNCTION__);
  
  int      idNimber=dataObject["id"].ToInt();
  double   volume=dataObject["volume"].ToDbl();
  double   SL=dataObject["stoploss"].ToDbl();
  double   TP=dataObject["takeprofit"].ToDbl();
  double   price=NormalizeDouble(dataObject["price"].ToDbl(),_Digits);
  double   deviation=dataObject["deviation"].ToDbl();  
  string   comment=dataObject["comment"].ToStr();
  double ask;
  double bid;
  
  // Order expiration section
  ENUM_ORDER_TYPE_TIME exp_type = ORDER_TIME_GTC;
  datetime expiration = 0;
  if (dataObject["expiration"].ToInt() != 0) {
  
    exp_type = ORDER_TIME_SPECIFIED;
    expiration=(datetime)dataObject["expiration"].ToInt();
  }
  
  // Market orders
  if(actionType=="ORDER_TYPE_BUY" || actionType=="ORDER_TYPE_SELL"){  
    ENUM_ORDER_TYPE orderType=ORDER_TYPE_BUY; 
    price = SymbolInfoDouble(symbol,SYMBOL_ASK);                                        
    if(actionType=="ORDER_TYPE_SELL") {
      orderType=ORDER_TYPE_SELL;
      price=SymbolInfoDouble(symbol,SYMBOL_BID);
    }
    
    if(trade.PositionOpen(symbol,orderType,volume,price,SL,TP,comment)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  
  // Pending orders
  else if(actionType=="ORDER_TYPE_BUY_LIMIT" || actionType=="ORDER_TYPE_SELL_LIMIT" || actionType=="ORDER_TYPE_BUY_STOP" || actionType=="ORDER_TYPE_SELL_STOP"){  
    if(actionType=="ORDER_TYPE_BUY_LIMIT"){
    // this is for limit if not possible market order
    bid=SymbolInfoDouble(symbol,SYMBOL_BID);
    ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
    if(ask<price){
       ENUM_ORDER_TYPE orderType=ORDER_TYPE_BUY; 
         if(trade.PositionOpen(symbol,orderType,volume,price,SL,TP,comment)){
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
         }
    }else{
         if(trade.BuyLimit(volume,price,symbol,SL,TP,ORDER_TIME_SPECIFIED,expiration,comment)){
           OrderDoneOrError(false, __FUNCTION__, trade);
           return;
         }
    }
      
    }
    else if(actionType=="ORDER_TYPE_SELL_LIMIT"){
    
    bid=SymbolInfoDouble(symbol,SYMBOL_BID);
    ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
    if(bid>price){
       ENUM_ORDER_TYPE orderType=ORDER_TYPE_SELL; 
         if(trade.PositionOpen(symbol,orderType,volume,price,SL,TP,comment)){
            OrderDoneOrError(false, __FUNCTION__, trade);
            return;
         }
    }else{
     if(trade.SellLimit(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment)){
          OrderDoneOrError(false, __FUNCTION__, trade);
           return;
          }
    
       } 
    }
    else if(actionType=="ORDER_TYPE_BUY_STOP"){
      if(trade.BuyStop(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment)){
        OrderDoneOrError(false, __FUNCTION__, trade);
        return;
      }
    }
    else if (actionType=="ORDER_TYPE_SELL_STOP"){
      if(trade.SellStop(volume,price,symbol,SL,TP,ORDER_TIME_GTC,expiration,comment)){
        OrderDoneOrError(false, __FUNCTION__, trade);
        return;
      }
    }
  }
  // Position modify    
  else if(actionType=="POSITION_MODIFY"){
    if(trade.PositionModify(idNimber,SL,TP)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Position close partial   
  else if(actionType=="POSITION_PARTIAL"){
    if(trade.PositionClosePartial(idNimber,volume)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Position close by id       
  else if(actionType=="POSITION_CLOSE_ID"){
    if(trade.PositionClose(idNimber)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Position close by symbol
  else if(actionType=="POSITION_CLOSE_SYMBOL"){
    if(trade.PositionClose(symbol)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Modify pending order
  else if(actionType=="ORDER_MODIFY"){  
    if(trade.OrderModify(idNimber,price,SL,TP,ORDER_TIME_GTC,expiration)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Cancel pending order  
  else if(actionType=="ORDER_CANCEL"){
    if(trade.OrderDelete(idNimber)){
      OrderDoneOrError(false, __FUNCTION__, trade);
      return;
    }
  }
  // Action type dosen't exist
  else ActionDoneOrError(65538, __FUNCTION__);
  
  // This part of the code runs if order was not completed
  OrderDoneOrError(true, __FUNCTION__, trade);
}

//+------------------------------------------------------------------+ 
//| TradeTransaction function                                        | 
//+------------------------------------------------------------------+ 
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result){
                        
                        
  api.OnTradeTransaction( trans, request, result );
  
}

//+------------------------------------------------------------------+
//| Convert chart timeframe from string to enum                      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetTimeframe(string chartTF){

  ENUM_TIMEFRAMES tf;
  
  if(chartTF=="TICK")  tf=PERIOD_CURRENT;
  else if(chartTF=="M1")  tf=PERIOD_M1;
  else if(chartTF=="M5")  tf=PERIOD_M5;
  else if(chartTF=="M15") tf=PERIOD_M15;
  else if(chartTF=="M30") tf=PERIOD_M30;
  else if(chartTF=="H1")  tf=PERIOD_H1;
  else if(chartTF=="H2")  tf=PERIOD_H2;
  else if(chartTF=="H3")  tf=PERIOD_H3;
  else if(chartTF=="H4")  tf=PERIOD_H4;
  else if(chartTF=="H6")  tf=PERIOD_H6;
  else if(chartTF=="H8")  tf=PERIOD_H8;
  else if(chartTF=="H12") tf=PERIOD_H12;
  else if(chartTF=="D1")  tf=PERIOD_D1;
  else if(chartTF=="W1")  tf=PERIOD_W1;
  else if(chartTF=="MN1") tf=PERIOD_MN1;
  //error will be raised in config function
  else tf=NULL;
  return(tf);
}
  
//+------------------------------------------------------------------+
//| Trade confirmation                                               |
//+------------------------------------------------------------------+
void OrderDoneOrError(bool error, string funcName, CTrade &trade){
  
  CJAVal conf;
  
  conf["error"]=(bool) error;
  conf["retcode"]=(int) trade.ResultRetcode();
  conf["desription"]=(string) GetRetcodeID(trade.ResultRetcode());
  // conf["deal"]=(int) trade.ResultDeal(); 
  conf["order"]=(int) trade.ResultOrder();
  conf["volume"]=(double) trade.ResultVolume();
  conf["price"]=(double) trade.ResultPrice();
  conf["bid"]=(double) trade.ResultBid();
  conf["ask"]=(double) trade.ResultAsk();
  conf["function"]=(string) funcName;
  
  string t=conf.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Action confirmation                                              |
//+------------------------------------------------------------------+
void ActionDoneOrError(int lastError, string funcName){
  
  CJAVal conf;
  
  conf["error"]=(bool)true;
  if(lastError==0) conf["error"]=(bool)false;
  
  conf["lastError"]=(string) lastError;
  conf["description"]=GetErrorID(lastError);
  conf["function"]=(string) funcName;
  
  string t=conf.Serialize();
  if(debug) Print(t);
  InformClientSocket(dataSocket,t);
}

//+------------------------------------------------------------------+
//| Inform Client via socket                                         |
//+------------------------------------------------------------------+
void InformClientSocket(Socket &workingSocket,string replyMessage){  
  
  // non-blocking
  workingSocket.send(replyMessage,true);   
  // TODO: Array out of range error
  ResetLastError();                                
}

//+------------------------------------------------------------------+
//| Get retcode message by retcode id                                |
//+------------------------------------------------------------------+   
string GetRetcodeID(int retcode){ 

  switch(retcode){ 
    case 10004: return("TRADE_RETCODE_REQUOTE");             break; 
    case 10006: return("TRADE_RETCODE_REJECT");              break; 
    case 10007: return("TRADE_RETCODE_CANCEL");              break; 
    case 10008: return("TRADE_RETCODE_PLACED");              break; 
    case 10009: return("TRADE_RETCODE_DONE");                break; 
    case 10010: return("TRADE_RETCODE_DONE_PARTIAL");        break; 
    case 10011: return("TRADE_RETCODE_ERROR");               break; 
    case 10012: return("TRADE_RETCODE_TIMEOUT");             break; 
    case 10013: return("TRADE_RETCODE_INVALID");             break; 
    case 10014: return("TRADE_RETCODE_INVALID_VOLUME");      break; 
    case 10015: return("TRADE_RETCODE_INVALID_PRICE");       break; 
    case 10016: return("TRADE_RETCODE_INVALID_STOPS");       break; 
    case 10017: return("TRADE_RETCODE_TRADE_DISABLED");      break; 
    case 10018: return("TRADE_RETCODE_MARKET_CLOSED");       break; 
    case 10019: return("TRADE_RETCODE_NO_MONEY");            break; 
    case 10020: return("TRADE_RETCODE_PRICE_CHANGED");       break; 
    case 10021: return("TRADE_RETCODE_PRICE_OFF");           break; 
    case 10022: return("TRADE_RETCODE_INVALID_EXPIRATION");  break; 
    case 10023: return("TRADE_RETCODE_ORDER_CHANGED");       break; 
    case 10024: return("TRADE_RETCODE_TOO_MANY_REQUESTS");   break; 
    case 10025: return("TRADE_RETCODE_NO_CHANGES");          break; 
    case 10026: return("TRADE_RETCODE_SERVER_DISABLES_AT");  break; 
    case 10027: return("TRADE_RETCODE_CLIENT_DISABLES_AT");  break; 
    case 10028: return("TRADE_RETCODE_LOCKED");              break; 
    case 10029: return("TRADE_RETCODE_FROZEN");              break; 
    case 10030: return("TRADE_RETCODE_INVALID_FILL");        break; 
    case 10031: return("TRADE_RETCODE_CONNECTION");          break; 
    case 10032: return("TRADE_RETCODE_ONLY_REAL");           break; 
    case 10033: return("TRADE_RETCODE_LIMIT_ORDERS");        break; 
    case 10034: return("TRADE_RETCODE_LIMIT_VOLUME");        break; 
    case 10035: return("TRADE_RETCODE_INVALID_ORDER");       break; 
    case 10036: return("TRADE_RETCODE_POSITION_CLOSED");     break; 
    case 10038: return("TRADE_RETCODE_INVALID_CLOSE_VOLUME");break; 
    case 10039: return("TRADE_RETCODE_CLOSE_ORDER_EXIST");   break; 
    case 10040: return("TRADE_RETCODE_LIMIT_POSITIONS");     break;  
    case 10041: return("TRADE_RETCODE_REJECT_CANCEL");       break; 
    case 10042: return("TRADE_RETCODE_LONG_ONLY");           break;
    case 10043: return("TRADE_RETCODE_SHORT_ONLY");          break;
    case 10044: return("TRADE_RETCODE_CLOSE_ONLY");          break;
    
    default: 
      return("TRADE_RETCODE_UNKNOWN="+IntegerToString(retcode)); 
      break; 
  } 
}
  
//+------------------------------------------------------------------+
//| Get error message by error id                                    |
//+------------------------------------------------------------------+ 
string GetErrorID(int error){

  switch(error){ 
    case 0:     return("ERR_SUCCESS");                        break; 
    case 4301:  return("ERR_MARKET_UNKNOWN_SYMBOL");          break;  
    case 4303:  return("ERR_MARKET_WRONG_PROPERTY");          break;
    case 4752:  return("ERR_TRADE_DISABLED");                 break;
    case 4753:  return("ERR_TRADE_POSITION_NOT_FOUND");       break;
    case 4754:  return("ERR_TRADE_ORDER_NOT_FOUND");          break; 
    // Custom errors
    case 65537: return("ERR_DESERIALIZATION");                break;
    case 65538: return("ERR_WRONG_ACTION");                   break;
    case 65539: return("ERR_WRONG_ACTION_TYPE");              break;
    case 65540: return("ERR_CLEAR_SUBSCRIPTIONS_FAILED");     break;
    case 65541: return("ERR_RETRIEVE_DATA_FAILED");     break;
    case 65542: return("ERR_CFILE_CREATION_FAILED");     break;
    
    
    default: 
      return("ERR_CODE_UNKNOWN="+IntegerToString(error)); 
      break; 
  }
}

//+------------------------------------------------------------------+
//| Return a textual description of the deinitialization reason code |
//+------------------------------------------------------------------+
string getUninitReasonText(int reasonCode)
  {
   string text="";
//---
   switch(reasonCode)
     {
      case REASON_ACCOUNT:
         text="Account was changed";break;
      case REASON_CHARTCHANGE:
         text="Symbol or timeframe was changed";break;
      case REASON_CHARTCLOSE:
         text="Chart was closed";break;
      case REASON_PARAMETERS:
         text="Input-parameter was changed";break;
      case REASON_RECOMPILE:
         text="Program "+__FILE__+" was recompiled";break;
      case REASON_REMOVE:
         text="Program "+__FILE__+" was removed from chart";break;
      case REASON_TEMPLATE:
         text="New template was applied to chart";break;
      default:text="Another reason";
     }
//---
   return text;
  }
