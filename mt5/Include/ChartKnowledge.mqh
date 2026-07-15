//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
//|  v3.90: только качественный вход — M1+M5+H1 в одну сторону         |
//+------------------------------------------------------------------+
#ifndef CHART_KNOWLEDGE_MQH
#define CHART_KNOWLEDGE_MQH

struct KnowledgeScore
  {
   double buy;
   double sell;
   string reason;
  };

struct MarketFlow
  {
   int    buy_v;
   int    sell_v;
   double m1_pts;
   double m5_pts;
   bool   clear;
   ENUM_ORDER_TYPE dir;
   string reason;
  };

//+------------------------------------------------------------------+
double BodyImpulse(const string sym, const ENUM_TIMEFRAMES tf, const int bars)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   int n = MathMax(bars, 2);
   if(CopyOpen(sym, tf, 1, n, o) < n) return 0.0;
   if(CopyClose(sym, tf, 1, n, c) < n) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += (c[i] - o[i]);
   return sum;
  }

//+------------------------------------------------------------------+
double CloseSlope(const string sym, const ENUM_TIMEFRAMES tf, const int look)
  {
   double c[];
   ArraySetAsSeries(c, true);
   int n = MathMax(look + 1, 2);
   if(CopyClose(sym, tf, 0, n, c) < n) return 0.0;
   return (c[0] - c[look]);
  }

//+------------------------------------------------------------------+
double Pts(const string sym, const double price_delta)
  {
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0) point = 1e-10;
   return price_delta / point;
  }

//+------------------------------------------------------------------+
double ATRPts(const string sym, const ENUM_TIMEFRAMES tf, const int period = 14)
  {
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return 50.0;
   double a[];
   ArraySetAsSeries(a, true);
   double v = 50.0;
   if(CopyBuffer(h, 0, 1, 1, a) >= 1)
      v = Pts(sym, a[0]);
   IndicatorRelease(h);
   return MathMax(v, 10.0);
  }

//+------------------------------------------------------------------+
void VoteSlope(const double slope_pts, const double thr,
               int &buy_v, int &sell_v, string &why, const string tag)
  {
   if(slope_pts >= thr)
     { buy_v++; why += tag + "↑ "; }
   else if(slope_pts <= -thr)
     { sell_v++; why += tag + "↓ "; }
  }

//+------------------------------------------------------------------+
int FormingCandleDir(const string sym, const ENUM_TIMEFRAMES tf, string &why, const string tag)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(sym, tf, 0, 1, o) < 1 || CopyClose(sym, tf, 0, 1, c) < 1)
      return 0;
   if(c[0] > o[0]) { why += tag + "↑ "; return 1; }
   if(c[0] < o[0]) { why += tag + "↓ "; return -1; }
   why += tag + "= ";
   return 0;
  }

//+------------------------------------------------------------------+
int ClosedCandleDir(const string sym, const ENUM_TIMEFRAMES tf, string &why, const string tag)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(sym, tf, 1, 1, o) < 1 || CopyClose(sym, tf, 1, 1, c) < 1)
      return 0;
   if(c[0] > o[0]) { why += tag + "↑ "; return 1; }
   if(c[0] < o[0]) { why += tag + "↓ "; return -1; }
   return 0;
  }

//+------------------------------------------------------------------+
// Качество > частота: не входим против минутного импульса.
MarketFlow ReadMarketFlow(const string sym)
  {
   MarketFlow f;
   f.buy_v = 0; f.sell_v = 0;
   f.m1_pts = 0; f.m5_pts = 0;
   f.clear = false;
   f.dir = ORDER_TYPE_BUY;
   f.reason = "";

   double atr_m1 = ATRPts(sym, PERIOD_M1, 14);
   double atr_m5 = ATRPts(sym, PERIOD_M5, 14);
   double thr_m1 = MathMax(atr_m1 * 0.25, 20.0);
   double thr_m5 = MathMax(atr_m5 * 0.18, 30.0);
   double thr_m15 = MathMax(ATRPts(sym, PERIOD_M15, 14) * 0.16, 40.0);
   double thr_h1 = MathMax(ATRPts(sym, PERIOD_H1, 14) * 0.10, 50.0);

   f.m1_pts = Pts(sym, CloseSlope(sym, PERIOD_M1, 8));
   f.m5_pts = Pts(sym, CloseSlope(sym, PERIOD_M5, 4));
   double m15_pts = Pts(sym, CloseSlope(sym, PERIOD_M15, 4));
   double h1_pts = Pts(sym, CloseSlope(sym, PERIOD_H1, 3));
   double m1_fast = Pts(sym, CloseSlope(sym, PERIOD_M1, 3));

   VoteSlope(f.m5_pts, thr_m5, f.buy_v, f.sell_v, f.reason, "M5");
   VoteSlope(m15_pts, thr_m15, f.buy_v, f.sell_v, f.reason, "M15");
   VoteSlope(h1_pts, thr_h1, f.buy_v, f.sell_v, f.reason, "H1");
   VoteSlope(f.m1_pts, thr_m1, f.buy_v, f.sell_v, f.reason, "M1");

   const int m5_now = FormingCandleDir(sym, PERIOD_M5, f.reason, "M5now");
   const int m15_now = FormingCandleDir(sym, PERIOD_M15, f.reason, "M15now");
   const int h1_now = FormingCandleDir(sym, PERIOD_H1, f.reason, "H1now");
   const int h1_cl = ClosedCandleDir(sym, PERIOD_H1, f.reason, "H1cl");
   if(m5_now > 0) f.buy_v++; else if(m5_now < 0) f.sell_v++;
   if(m15_now > 0) f.buy_v++; else if(m15_now < 0) f.sell_v++;
   if(h1_now > 0) f.buy_v++; else if(h1_now < 0) f.sell_v++;
   if(h1_cl > 0) f.buy_v++; else if(h1_cl < 0) f.sell_v++;

   bool above_ema = false, below_ema = false;
   int ema = iMA(sym, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(ema != INVALID_HANDLE)
     {
      double e[];
      ArraySetAsSeries(e, true);
      if(CopyBuffer(ema, 0, 0, 2, e) >= 2)
        {
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);
         double dead = SymbolInfoDouble(sym, SYMBOL_POINT) * MathMax(thr_m1 * 0.2, 10.0);
         if(bid > e[0] + dead) { f.buy_v++; above_ema = true; f.reason += "aboveEMA5 "; }
         else if(bid < e[0] - dead) { f.sell_v++; below_ema = true; f.reason += "belowEMA5 "; }
         else f.reason += "nearEMA5 ";
        }
      IndicatorRelease(ema);
     }

   if(m1_fast >= thr_m1 * 0.55) f.reason += "M1f↑ ";
   else if(m1_fast <= -thr_m1 * 0.55) f.reason += "M1f↓ ";

   f.reason += StringFormat("|M1=%.0f M5=%.0f M15=%.0f H1=%.0f", f.m1_pts, f.m5_pts, m15_pts, h1_pts);

   // M1 обязательно с нами — иначе мгновенный минус на золоте
   const bool m1_with_buy  = (f.m1_pts >= thr_m1 * 0.35 && m1_fast >= -thr_m1 * 0.25);
   const bool m1_with_sell = (f.m1_pts <= -thr_m1 * 0.35 && m1_fast <= thr_m1 * 0.25);

   // Структура: закрытый H1 или сильный наклон H1 + текущие M5/H1
   const bool struct_buy =
      (h1_cl > 0 || h1_pts >= thr_h1 * 0.35 || h1_now > 0) &&
      (m5_now > 0) &&
      (above_ema || m15_now > 0 || f.m5_pts > 0);
   const bool struct_sell =
      (h1_cl < 0 || h1_pts <= -thr_h1 * 0.35 || h1_now < 0) &&
      (m5_now < 0) &&
      (below_ema || m15_now < 0 || f.m5_pts < 0);

   // Не покупать в красный H1-сейчас; не продавать в зелёный H1-сейчас
   const bool wick_blocks_buy  = (h1_now < 0 && h1_cl <= 0);
   const bool wick_blocks_sell = (h1_now > 0 && h1_cl >= 0);

   if(struct_buy && m1_with_buy && !wick_blocks_buy && f.buy_v >= f.sell_v + 2 && f.buy_v >= 4)
     {
      f.dir = ORDER_TYPE_BUY;
      f.clear = true;
      f.reason = "QUALITY " + f.reason;
     }
   else if(struct_sell && m1_with_sell && !wick_blocks_sell && f.sell_v >= f.buy_v + 2 && f.sell_v >= 4)
     {
      f.dir = ORDER_TYPE_SELL;
      f.clear = true;
      f.reason = "QUALITY " + f.reason;
     }
   else
     {
      f.clear = false;
      if(f.buy_v > f.sell_v) f.dir = ORDER_TYPE_BUY;
      else if(f.sell_v > f.buy_v) f.dir = ORDER_TYPE_SELL;
      else f.dir = (f.m1_pts >= 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      f.reason = "CHOP " + f.reason;
      if(!m1_with_buy && !m1_with_sell) f.reason = "WAIT_M1 " + f.reason;
     }

   return f;
  }

//+------------------------------------------------------------------+
KnowledgeScore EvaluateKnowledge(const string sym,
                                 const ENUM_TIMEFRAMES /*signal_tf*/,
                                 const bool /*trend_up*/,
                                 const bool /*trend_down*/)
  {
   MarketFlow f = ReadMarketFlow(sym);
   KnowledgeScore s;
   s.buy = (double)f.buy_v * 10.0 + MathMax(0.0, f.m1_pts) / 20.0;
   s.sell = (double)f.sell_v * 10.0 + MathMax(0.0, -f.m1_pts) / 20.0;
   s.reason = f.reason;
   if(!f.clear)
      s.reason = "WAIT " + s.reason;
   return s;
  }

//+------------------------------------------------------------------+
void KnowledgeForceDirWithTieBreak(const string sym,
                                   const KnowledgeScore &ks,
                                   ENUM_ORDER_TYPE &type,
                                   string &reason)
  {
   MarketFlow f = ReadMarketFlow(sym);
   type = f.dir;
   if(f.clear)
      reason = StringFormat("FLOW %s B%d/S%d %s",
                            f.dir == ORDER_TYPE_BUY ? "BUY" : "SELL",
                            f.buy_v, f.sell_v, f.reason);
   else
      reason = StringFormat("NOCLEAR B%d/S%d %s", f.buy_v, f.sell_v, f.reason);
   if(ks.buy >= 0) { /* keep */ }
  }

#endif
//+------------------------------------------------------------------+
