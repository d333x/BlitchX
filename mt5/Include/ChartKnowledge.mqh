//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
//|  v3: куда идёт РЫНОК СЕЙЧАС (M1/M5 импульс) + подтверждение M15   |
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
   double m1_pts;   // ход M1 за look-баров (со знаком)
   double m5_pts;
   bool   clear;    // достаточно голосов и М1 согласен
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
   // shift 0 = текущая (формирующаяся) свеча — живой рынок
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
// Голос: +1 buy / +1 sell. thr_pts — порог в пунктах.
void VoteSlope(const double slope_pts, const double thr,
               int &buy_v, int &sell_v, string &why, const string tag)
  {
   if(slope_pts >= thr)
     { buy_v++; why += tag + "↑ "; }
   else if(slope_pts <= -thr)
     { sell_v++; why += tag + "↓ "; }
  }

//+------------------------------------------------------------------+
// Главное: куда идёт рынок прямо сейчас.
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
   // Порог: доля ATR — чтобы не ловить шум спреда
   double thr_m1 = MathMax(atr_m1 * 0.35, 25.0);
   double thr_m5 = MathMax(atr_m5 * 0.25, 40.0);
   double thr_m15 = MathMax(ATRPts(sym, PERIOD_M15, 14) * 0.20, 50.0);

   f.m1_pts = Pts(sym, CloseSlope(sym, PERIOD_M1, 8));
   f.m5_pts = Pts(sym, CloseSlope(sym, PERIOD_M5, 4));
   double m15_pts = Pts(sym, CloseSlope(sym, PERIOD_M15, 4));
   double m1_fast = Pts(sym, CloseSlope(sym, PERIOD_M1, 3)); // короткий импульс

   VoteSlope(f.m1_pts, thr_m1, f.buy_v, f.sell_v, f.reason, "M1");
   VoteSlope(m1_fast, thr_m1 * 0.6, f.buy_v, f.sell_v, f.reason, "M1f");
   VoteSlope(f.m5_pts, thr_m5, f.buy_v, f.sell_v, f.reason, "M5");
   VoteSlope(m15_pts, thr_m15, f.buy_v, f.sell_v, f.reason, "M15");

   // Цена vs EMA20 на M5 (живой)
   int ema = iMA(sym, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(ema != INVALID_HANDLE)
     {
      double e[];
      ArraySetAsSeries(e, true);
      if(CopyBuffer(ema, 0, 0, 2, e) >= 2)
        {
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);
         if(bid > e[0]) { f.buy_v++; f.reason += "aboveEMA5 "; }
         else           { f.sell_v++; f.reason += "belowEMA5 "; }
        }
      IndicatorRelease(ema);
     }

   // Формирующаяся M5 свеча
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(sym, PERIOD_M5, 0, 1, o) >= 1 && CopyClose(sym, PERIOD_M5, 0, 1, c) >= 1)
     {
      if(c[0] > o[0]) { f.buy_v++; f.reason += "M5now↑ "; }
      else if(c[0] < o[0]) { f.sell_v++; f.reason += "M5now↓ "; }
     }

   f.reason += StringFormat("|M1=%.0f M5=%.0f thr1=%.0f", f.m1_pts, f.m5_pts, thr_m1);

   // Чёткий сигнал: перевес голосов И короткий M1 в ту же сторону
   if(f.buy_v >= f.sell_v + 2 && f.m1_pts > 0 && m1_fast >= 0)
     {
      f.dir = ORDER_TYPE_BUY;
      f.clear = (f.buy_v >= 3);
     }
   else if(f.sell_v >= f.buy_v + 2 && f.m1_pts < 0 && m1_fast <= 0)
     {
      f.dir = ORDER_TYPE_SELL;
      f.clear = (f.sell_v >= 3);
     }
   else
     {
      f.clear = false;
      if(f.buy_v > f.sell_v) f.dir = ORDER_TYPE_BUY;
      else if(f.sell_v > f.buy_v) f.dir = ORDER_TYPE_SELL;
      else f.dir = (f.m1_pts >= 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      f.reason = "CHOP " + f.reason;
     }

   return f;
  }

//+------------------------------------------------------------------+
// Оценка силы для lock / panel (совместимость)
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
   // scores already in ks for panel
   if(ks.buy >= 0) { /* keep */ }
  }

#endif
//+------------------------------------------------------------------+
