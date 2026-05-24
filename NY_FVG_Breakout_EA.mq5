//+------------------------------------------------------------------+
//|                                         NY_FVG_Breakout_EA.mq5   |
//|                       New York Session FVG Breakout Robot (MT5)  |
//+------------------------------------------------------------------+
#property copyright "opus7777"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs
input double InpLotSize          = 0.10;   // Fixed lot size
input double InpRiskReward       = 2.0;    // Risk : Reward ratio (TP = RR * SL)
input int    InpNYStartHour      = 9;      // NY session start hour (broker server time)
input int    InpNYStartMinute    = 30;     // NY session start minute
input int    InpNYRangeMinutes   = 5;      // Range window length in minutes (09:30 - 09:35 => 5)
input int    InpEntryWindowMin   = 180;    // Minutes after the range to look for setup
input int    InpMagic            = 99231;  // Magic number
input bool   InpAllowMultiple    = false;  // Allow multiple trades per session
input bool   InpDrawObjects      = true;   // Draw boxes / lines on chart

//--- Globals
CTrade        trade;
datetime      g_sessionDay   = 0;       // Day for which the range was computed
double        g_rangeHigh    = 0.0;
double        g_rangeLow     = 0.0;
datetime      g_rangeStart   = 0;
datetime      g_rangeEnd     = 0;

bool          g_bullBreak    = false;   // Bullish break of g_rangeHigh has occurred
bool          g_bearBreak    = false;   // Bearish break of g_rangeLow has occurred

bool          g_haveBullFVG  = false;   // FVG in direction of bullish break
double        g_bullFVGtop   = 0.0;     // top  of bullish FVG (low of candle that created the gap)
double        g_bullFVGbot   = 0.0;     // bot  of bullish FVG (high of candle two bars before)
datetime      g_bullFVGtime  = 0;

bool          g_haveBearFVG  = false;
double        g_bearFVGtop   = 0.0;     // top of bearish FVG (low of candle two bars before)
double        g_bearFVGbot   = 0.0;     // bot of bearish FVG (high of candle that created the gap)
datetime      g_bearFVGtime  = 0;

bool          g_priceReturnedBullFVG = false;
bool          g_priceReturnedBearFVG = false;

bool          g_tradedThisSession = false;

//+------------------------------------------------------------------+
//| Helper: build datetime for a given hour/minute on a given day    |
//+------------------------------------------------------------------+
datetime BuildTime(datetime day, int hour, int minute)
{
   MqlDateTime t;
   TimeToStruct(day, t);
   t.hour = hour;
   t.min  = minute;
   t.sec  = 0;
   return StructToTime(t);
}

//+------------------------------------------------------------------+
//| Reset all session state                                          |
//+------------------------------------------------------------------+
void ResetSession()
{
   g_rangeHigh = 0.0;
   g_rangeLow  = 0.0;
   g_rangeStart = 0;
   g_rangeEnd   = 0;
   g_bullBreak = false;
   g_bearBreak = false;
   g_haveBullFVG = false;
   g_haveBearFVG = false;
   g_priceReturnedBullFVG = false;
   g_priceReturnedBearFVG = false;
   g_tradedThisSession = false;
}

//+------------------------------------------------------------------+
//| Compute the 09:30 - 09:35 M5 range high / low for today          |
//+------------------------------------------------------------------+
bool ComputeRange(datetime now)
{
   MqlDateTime t;
   TimeToStruct(now, t);
   datetime dayStart = BuildTime(now, 0, 0);

   datetime rangeStart = BuildTime(now, InpNYStartHour, InpNYStartMinute);
   datetime rangeEnd   = rangeStart + InpNYRangeMinutes * 60;

   //--- Need range to be fully formed
   if(now < rangeEnd)
      return false;

   //--- Pull M5 candles in the window. For 09:30-09:35 there is exactly one M5 candle (09:30).
   //--- We still scan a small buffer to be tolerant of variable window lengths.
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M5, rangeStart, rangeEnd - 1, rates);
   if(copied <= 0)
      return false;

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;
   for(int i = 0; i < copied; ++i)
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
      string nameH = StringFormat("NYRangeHi_%d", (int)dayStart);
      string nameL = StringFormat("NYRangeLo_%d", (int)dayStart);
      ObjectDelete(0, nameH);
      ObjectDelete(0, nameL);
      ObjectCreate(0, nameH, OBJ_HLINE, 0, 0, g_rangeHigh);
      ObjectCreate(0, nameL, OBJ_HLINE, 0, 0, g_rangeLow);
      ObjectSetInteger(0, nameH, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, nameL, OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, nameH, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DOT);
   }

   PrintFormat("NY range built: High=%.5f  Low=%.5f  (%s -> %s)",
               g_rangeHigh, g_rangeLow,
               TimeToString(g_rangeStart, TIME_MINUTES),
               TimeToString(g_rangeEnd,   TIME_MINUTES));
   return true;
}

//+------------------------------------------------------------------+
//| Detect M1 body-break of the range                                |
//|   Bullish break: close > high AND open > high (full body above)  |
//|   Bearish break: close < low  AND open < low  (full body below)  |
//+------------------------------------------------------------------+
void CheckBodyBreak()
{
   if(g_bullBreak && g_bearBreak) return;

   MqlRates m1[];
   if(CopyRates(_Symbol, PERIOD_M1, g_rangeEnd, TimeCurrent(), m1) <= 0) return;

   for(int i = 0; i < ArraySize(m1); ++i)
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
//| After break, search for a 3-candle FVG on M1                     |
//|   Bullish FVG: low[i]  > high[i-2]  (gap between candle i-2 high |
//|                                      and candle i low)           |
//|   Bearish FVG: high[i] < low[i-2]                                |
//+------------------------------------------------------------------+
void CheckFVG()
{
   if((g_bullBreak && !g_haveBullFVG) || (g_bearBreak && !g_haveBearFVG))
   {
      MqlRates m1[];
      if(CopyRates(_Symbol, PERIOD_M1, g_rangeEnd, TimeCurrent(), m1) <= 2) return;

      for(int i = 2; i < ArraySize(m1); ++i)
      {
         //--- Bullish FVG
         if(g_bullBreak && !g_haveBullFVG)
         {
            if(m1[i].low > m1[i-2].high)
            {
               g_haveBullFVG = true;
               g_bullFVGbot  = m1[i-2].high;   // bottom of the gap
               g_bullFVGtop  = m1[i].low;      // top of the gap
               g_bullFVGtime = m1[i].time;
               PrintFormat("Bullish FVG detected %.5f - %.5f at %s",
                           g_bullFVGbot, g_bullFVGtop,
                           TimeToString(g_bullFVGtime, TIME_DATE | TIME_MINUTES));
               DrawFVGBox("BullFVG", g_bullFVGtime, g_bullFVGbot, g_bullFVGtop, clrLimeGreen);
            }
         }
         //--- Bearish FVG
         if(g_bearBreak && !g_haveBearFVG)
         {
            if(m1[i].high < m1[i-2].low)
            {
               g_haveBearFVG = true;
               g_bearFVGtop  = m1[i-2].low;
               g_bearFVGbot  = m1[i].high;
               g_bearFVGtime = m1[i].time;
               PrintFormat("Bearish FVG detected %.5f - %.5f at %s",
                           g_bearFVGbot, g_bearFVGtop,
                           TimeToString(g_bearFVGtime, TIME_DATE | TIME_MINUTES));
               DrawFVGBox("BearFVG", g_bearFVGtime, g_bearFVGbot, g_bearFVGtop, clrCrimson);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Draw an FVG zone as a rectangle                                  |
//+------------------------------------------------------------------+
void DrawFVGBox(const string prefix, datetime t, double bot, double top, color c)
{
   if(!InpDrawObjects) return;
   string name = StringFormat("%s_%d", prefix, (int)t);
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t, bot, t + 60 * 60, top);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
}

//+------------------------------------------------------------------+
//| Mark FVG as retested once price prints inside the gap            |
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
//| Engulfing pattern on the last *closed* M1 candle                 |
//|   Bullish: prev red, curr green, curr.open<=prev.close,          |
//|                                  curr.close>=prev.open           |
//|   Bearish: mirror                                                |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(const MqlRates &prev, const MqlRates &curr)
{
   bool prevDown = prev.close < prev.open;
   bool currUp   = curr.close > curr.open;
   return (prevDown && currUp &&
           curr.open  <= prev.close &&
           curr.close >= prev.open);
}
bool IsBearishEngulfing(const MqlRates &prev, const MqlRates &curr)
{
   bool prevUp   = prev.close > prev.open;
   bool currDown = curr.close < curr.open ? false : true; // sanity
   currDown = (curr.close < curr.open);
   return (prevUp && currDown &&
           curr.open  >= prev.close &&
           curr.close <= prev.open);
}

//+------------------------------------------------------------------+
//| Place trade with 1:RR risk-reward                                |
//+------------------------------------------------------------------+
void PlaceTrade(bool buy, double slPrice)
{
   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                      : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double dist  = MathAbs(price - slPrice);
   if(dist <= 0) return;

   double tpPrice = buy ? price + dist * InpRiskReward
                        : price - dist * InpRiskReward;

   trade.SetExpertMagicNumber(InpMagic);
   bool ok = buy ? trade.Buy (InpLotSize, _Symbol, price, slPrice, tpPrice, "NY-FVG")
                 : trade.Sell(InpLotSize, _Symbol, price, slPrice, tpPrice, "NY-FVG");

   if(ok)
   {
      g_tradedThisSession = true;
      PrintFormat("%s order placed @ %.5f  SL=%.5f  TP=%.5f",
                  buy ? "BUY" : "SELL", price, slPrice, tpPrice);
   }
   else
      PrintFormat("Order failed: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Check engulfing & execute                                        |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(g_tradedThisSession && !InpAllowMultiple) return;

   MqlRates m1[];
   if(CopyRates(_Symbol, PERIOD_M1, 0, 3, m1) < 3) return;
   //--- m1[0]=oldest, m1[2]=current (forming), use m1[1] as last closed, m1[0] as prior closed
   MqlRates prev = m1[0];
   MqlRates curr = m1[1];

   if(g_priceReturnedBullFVG && IsBullishEngulfing(prev, curr))
   {
      double sl = MathMin(curr.low, g_bullFVGbot) - _Point * 2;
      PlaceTrade(true, sl);
      g_priceReturnedBullFVG = false; // consume signal
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
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);

   //--- New day => reset
   datetime dayStart = BuildTime(now, 0, 0);
   if(dayStart != g_sessionDay)
      ResetSession();

   //--- Build range once it's complete
   if(g_rangeEnd == 0)
   {
      if(!ComputeRange(now))
         return;
   }

   //--- Only run logic for a limited window after the range
   if(now > g_rangeEnd + InpEntryWindowMin * 60) return;

   CheckBodyBreak();
   CheckFVG();
   CheckFVGReturn();

   //--- Only evaluate entry on new M1 bar close to avoid duplicates
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar != lastBar)
   {
      lastBar = curBar;
      CheckEntry();
   }
}
//+------------------------------------------------------------------+
