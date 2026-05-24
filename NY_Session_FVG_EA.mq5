//+------------------------------------------------------------------+
//|                                            NY_Session_FVG_EA.mq5 |
//|                       New York Session FVG Breakout Robot (MT5) |
//+------------------------------------------------------------------+
#property copyright "opus7777"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Inputs
input double InpLotSize        = 0.10;   // Fixed lot size
input double InpRiskReward     = 2.0;    // Risk:Reward (TP = RR * SL distance)
input int    InpNYStartHour    = 9;      // NY session start hour (server time)
input int    InpNYStartMinute  = 30;     // NY session start minute
input int    InpNYRangeMinutes = 5;      // Range length in minutes (09:30-09:35 = 5)
input int    InpEntryWindowMin = 180;    // Minutes after range to look for setup
input int    InpMagic          = 99231;  // Magic number
input bool   InpAllowMultiple  = false;  // Allow multiple trades per session
input bool   InpDrawObjects    = true;   // Draw boxes/lines on chart

//--- Globals
CTrade   trade;
datetime g_sessionDay  = 0;
double   g_rangeHigh   = 0.0;
double   g_rangeLow    = 0.0;
datetime g_rangeStart  = 0;
datetime g_rangeEnd    = 0;

bool     g_bullBreak   = false;
bool     g_bearBreak   = false;

bool     g_haveBullFVG = false;
double   g_bullFVGtop  = 0.0;
double   g_bullFVGbot  = 0.0;
datetime g_bullFVGtime = 0;

bool     g_haveBearFVG = false;
double   g_bearFVGtop  = 0.0;
double   g_bearFVGbot  = 0.0;
datetime g_bearFVGtime = 0;

bool     g_priceReturnedBullFVG = false;
bool     g_priceReturnedBearFVG = false;

bool     g_tradedThisSession    = false;

//+------------------------------------------------------------------+
//| Build datetime for a given hour/minute on the calendar day of t  |
//+------------------------------------------------------------------+
datetime BuildTime(datetime t, int hour, int minute)
{
   MqlDateTime mt;
   TimeToStruct(t, mt);
   mt.hour = hour;
   mt.min  = minute;
   mt.sec  = 0;
   return StructToTime(mt);
}

//+------------------------------------------------------------------+
//| Reset session state                                              |
//+------------------------------------------------------------------+
void ResetSession()
{
   g_rangeHigh    = 0.0;
   g_rangeLow     = 0.0;
   g_rangeStart   = 0;
   g_rangeEnd     = 0;
   g_bullBreak    = false;
   g_bearBreak    = false;
   g_haveBullFVG  = false;
   g_haveBearFVG  = false;
   g_priceReturnedBullFVG = false;
   g_priceReturnedBearFVG = false;
   g_tradedThisSession    = false;
}

//+------------------------------------------------------------------+
//| Compute the M5 range high/low for the 09:30-09:35 window         |
//+------------------------------------------------------------------+
bool ComputeRange(datetime now)
{
   datetime dayStart   = BuildTime(now, 0, 0);
   datetime rangeStart = BuildTime(now, InpNYStartHour, InpNYStartMinute);
   datetime rangeEnd   = rangeStart + InpNYRangeMinutes * 60;

   if(now < rangeEnd)
      return false;

   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M5, rangeStart, rangeEnd - 1, rates);
   if(copied <= 0)
      return false;

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;
   for(int i = 0; i < copied; i++)
   {
      if(rates[i].time < rangeStart || rates[i].time >= rangeEnd) continue;
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
   }
   if(hi == -DBL_MAX || lo == DBL_MAX)
      return false;

   g_rangeHigh  = hi;
   g_rangeLow   = lo;
   g_rangeStart = rangeStart;
   g_rangeEnd   = rangeEnd;
   g_sessionDay = dayStart;

   if(InpDrawObjects)
   {
      string nameH = "NYRangeHi_" + IntegerToString((int)dayStart);
      string nameL = "NYRangeLo_" + IntegerToString((int)dayStart);
      ObjectDelete(0, nameH);
      ObjectDelete(0, nameL);
      ObjectCreate(0, nameH, OBJ_HLINE, 0, 0, g_rangeHigh);
      ObjectCreate(0, nameL, OBJ_HLINE, 0, 0, g_rangeLow);
      ObjectSetInteger(0, nameH, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, nameL, OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, nameH, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DOT);
   }

   PrintFormat("NY range built: H=%.5f  L=%.5f  (%s -> %s)",
               g_rangeHigh, g_rangeLow,
               TimeToString(g_rangeStart, TIME_MINUTES),
               TimeToString(g_rangeEnd,   TIME_MINUTES));
   return true;
}

//+------------------------------------------------------------------+
//| Detect M1 body break (entire candle body beyond the range edge)  |
//+------------------------------------------------------------------+
void CheckBodyBreak()
{
   if(g_bullBreak && g_bearBreak) return;

   MqlRates m1[];
   int copied = CopyRates(_Symbol, PERIOD_M1, g_rangeEnd, TimeCurrent(), m1);
   if(copied <= 0) return;

   for(int i = 0; i < copied; i++)
   {
      double op = m1[i].open;
      double cl = m1[i].close;
      double bodyHi = MathMax(op, cl);
      double bodyLo = MathMin(op, cl);

      if(!g_bullBreak && bodyLo > g_rangeHigh)
      {
         g_bullBreak = true;
         PrintFormat("Bullish M1 body-break of range high at %s",
                     TimeToString(m1[i].time, TIME_DATE | TIME_MINUTES));
      }
      if(!g_bearBreak && bodyHi < g_rangeLow)
      {
         g_bearBreak = true;
         PrintFormat("Bearish M1 body-break of range low at %s",
                     TimeToString(m1[i].time, TIME_DATE | TIME_MINUTES));
      }
   }
}

//+------------------------------------------------------------------+
//| Draw an FVG zone as a filled rectangle                           |
//+------------------------------------------------------------------+
void DrawFVGBox(const string prefix, datetime t, double bot, double top, color c)
{
   if(!InpDrawObjects) return;
   string name = prefix + "_" + IntegerToString((int)t);
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t, bot, t + 60 * 60, top);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_FILL,  true);
}

//+------------------------------------------------------------------+
//| Scan for 3-candle FVG after the body break                       |
//+------------------------------------------------------------------+
void CheckFVG()
{
   if(!g_bullBreak && !g_bearBreak) return;
   if(g_haveBullFVG && g_haveBearFVG) return;

   MqlRates m1[];
   int copied = CopyRates(_Symbol, PERIOD_M1, g_rangeEnd, TimeCurrent(), m1);
   if(copied <= 2) return;

   for(int i = 2; i < copied; i++)
   {
      if(g_bullBreak && !g_haveBullFVG)
      {
         if(m1[i].low > m1[i-2].high)
         {
            g_haveBullFVG = true;
            g_bullFVGbot  = m1[i-2].high;
            g_bullFVGtop  = m1[i].low;
            g_bullFVGtime = m1[i].time;
            PrintFormat("Bullish FVG %.5f-%.5f at %s",
                        g_bullFVGbot, g_bullFVGtop,
                        TimeToString(g_bullFVGtime, TIME_DATE | TIME_MINUTES));
            DrawFVGBox("BullFVG", g_bullFVGtime, g_bullFVGbot, g_bullFVGtop, clrLimeGreen);
         }
      }
      if(g_bearBreak && !g_haveBearFVG)
      {
         if(m1[i].high < m1[i-2].low)
         {
            g_haveBearFVG = true;
            g_bearFVGtop  = m1[i-2].low;
            g_bearFVGbot  = m1[i].high;
            g_bearFVGtime = m1[i].time;
            PrintFormat("Bearish FVG %.5f-%.5f at %s",
                        g_bearFVGbot, g_bearFVGtop,
                        TimeToString(g_bearFVGtime, TIME_DATE | TIME_MINUTES));
            DrawFVGBox("BearFVG", g_bearFVGtime, g_bearFVGbot, g_bearFVGtop, clrCrimson);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect when price returns inside the FVG                         |
//+------------------------------------------------------------------+
void CheckFVGReturn()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_haveBullFVG && !g_priceReturnedBullFVG)
   {
      if(bid <= g_bullFVGtop && bid >= g_bullFVGbot)
      {
         g_priceReturnedBullFVG = true;
         Print("Price returned into Bullish FVG - waiting for engulfing");
      }
   }
   if(g_haveBearFVG && !g_priceReturnedBearFVG)
   {
      if(ask >= g_bearFVGbot && ask <= g_bearFVGtop)
      {
         g_priceReturnedBearFVG = true;
         Print("Price returned into Bearish FVG - waiting for engulfing");
      }
   }
}

//+------------------------------------------------------------------+
//| Engulfing pattern helpers (on last closed M1 candle)             |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &prev, const MqlRates &curr)
{
   bool prevDown = (prev.close < prev.open);
   bool currUp   = (curr.close > curr.open);
   if(!prevDown || !currUp) return false;
   return (curr.open <= prev.close && curr.close >= prev.open);
}

bool IsBearishEngulfing(const MqlRates &prev, const MqlRates &curr)
{
   bool prevUp   = (prev.close > prev.open);
   bool currDown = (curr.close < curr.open);
   if(!prevUp || !currDown) return false;
   return (curr.open >= prev.close && curr.close <= prev.open);
}

//+------------------------------------------------------------------+
//| Place trade with 1:RR risk/reward                                |
//+------------------------------------------------------------------+
void PlaceTrade(bool buy, double slPrice)
{
   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double dist  = MathAbs(price - slPrice);
   if(dist <= 0.0) return;

   double tpPrice = buy ? price + dist * InpRiskReward
                        : price - dist * InpRiskReward;

   trade.SetExpertMagicNumber(InpMagic);
   bool ok = false;
   if(buy)
      ok = trade.Buy(InpLotSize, _Symbol, price, slPrice, tpPrice, "NY-FVG");
   else
      ok = trade.Sell(InpLotSize, _Symbol, price, slPrice, tpPrice, "NY-FVG");

   if(ok)
   {
      g_tradedThisSession = true;
      PrintFormat("%s @ %.5f  SL=%.5f  TP=%.5f",
                  buy ? "BUY" : "SELL", price, slPrice, tpPrice);
   }
   else
   {
      PrintFormat("Order failed: %d - %s",
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Evaluate engulfing on last closed M1 candle and execute          |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(g_tradedThisSession && !InpAllowMultiple) return;

   MqlRates m1[];
   int copied = CopyRates(_Symbol, PERIOD_M1, 0, 3, m1);
   if(copied < 3) return;

   MqlRates prev = m1[0];
   MqlRates curr = m1[1];

   if(g_priceReturnedBullFVG && IsBullishEngulfing(prev, curr))
   {
      double sl = MathMin(curr.low, g_bullFVGbot) - _Point * 2;
      PlaceTrade(true, sl);
      g_priceReturnedBullFVG = false;
   }
   if(g_priceReturnedBearFVG && IsBearishEngulfing(prev, curr))
   {
      double sl = MathMax(curr.high, g_bearFVGtop) + _Point * 2;
      PlaceTrade(false, sl);
      g_priceReturnedBearFVG = false;
   }
}

//+------------------------------------------------------------------+
//| Expert init / deinit                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   ResetSession();
   trade.SetExpertMagicNumber(InpMagic);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now      = TimeCurrent();
   datetime dayStart = BuildTime(now, 0, 0);

   if(dayStart != g_sessionDay)
      ResetSession();

   if(g_rangeEnd == 0)
   {
      if(!ComputeRange(now))
         return;
   }

   if(now > g_rangeEnd + InpEntryWindowMin * 60) return;

   CheckBodyBreak();
   CheckFVG();
   CheckFVGReturn();

   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar != lastBar)
   {
      lastBar = curBar;
      CheckEntry();
   }
}
//+------------------------------------------------------------------+
