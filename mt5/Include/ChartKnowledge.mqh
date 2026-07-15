//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
 //|  v3.94: мгновенный сигнал BUY/SELL/WAIT + веса ТФ + уверенность  |
//+------------------------------------------------------------------+
#ifndef CHART_KNOWLEDGE_MQH
#define CHART_KNOWLEDGE_MQH

enum ENUM_MARKET_SIGNAL
  {
   SIG_WAIT = 0,
   SIG_BUY  = 1,
   SIG_SELL = 2
  };

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
   bool   clear;                 // можно входить
   ENUM_ORDER_TYPE dir;          // текущий bias (всегда есть)
   string reason;
   // v3.94
   ENUM_MARKET_SIGNAL signal;    // WAIT / BUY / SELL для панели
   double buy_w;                 // взвешенный buy
   double sell_w;                // взвешенный sell
   double conf;                  // 0..100 уверенность
   string signal_txt;            // "СИГНАЛ: BUY 78%" и т.п.
   string analysis;              // краткий разбор ТФ
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
void AddWeight(const int dir, const double w, double &buy_w, double &sell_w,
               int &buy_v, int &sell_v)
  {
   if(dir > 0)
     { buy_w += w; buy_v++; }
   else if(dir < 0)
     { sell_w += w; sell_v++; }
  }

//+------------------------------------------------------------------+
int SlopeDir(const double slope_pts, const double thr)
  {
   if(slope_pts >= thr) return 1;
   if(slope_pts <= -thr) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
// Мгновенный предикт: bias всегда есть; clear = вход разрешён.
MarketFlow ReadMarketFlow(const string sym)
  {
   MarketFlow f;
   f.buy_v = 0; f.sell_v = 0;
   f.m1_pts = 0; f.m5_pts = 0;
   f.clear = false;
   f.dir = ORDER_TYPE_BUY;
   f.reason = "";
   f.signal = SIG_WAIT;
   f.buy_w = 0; f.sell_w = 0;
   f.conf = 0;
   f.signal_txt = "СИГНАЛ: ЖДЁМ";
   f.analysis = "";

   double atr_m1 = ATRPts(sym, PERIOD_M1, 14);
   double atr_m5 = ATRPts(sym, PERIOD_M5, 14);
   double atr_m15 = ATRPts(sym, PERIOD_M15, 14);
   double atr_h1 = ATRPts(sym, PERIOD_H1, 14);
   double thr_m1 = MathMax(atr_m1 * 0.22, 18.0);
   double thr_m5 = MathMax(atr_m5 * 0.16, 25.0);
   double thr_m15 = MathMax(atr_m15 * 0.14, 35.0);
   double thr_h1 = MathMax(atr_h1 * 0.09, 45.0);

   f.m1_pts = Pts(sym, CloseSlope(sym, PERIOD_M1, 8));
   f.m5_pts = Pts(sym, CloseSlope(sym, PERIOD_M5, 4));
   double m15_pts = Pts(sym, CloseSlope(sym, PERIOD_M15, 4));
   double h1_pts = Pts(sym, CloseSlope(sym, PERIOD_H1, 3));
   double m1_fast = Pts(sym, CloseSlope(sym, PERIOD_M1, 3));

   const int d_m5  = SlopeDir(f.m5_pts, thr_m5);
   const int d_m15 = SlopeDir(m15_pts, thr_m15);
   const int d_h1  = SlopeDir(h1_pts, thr_h1);
   const int d_m1  = SlopeDir(f.m1_pts, thr_m1);

   VoteSlope(f.m5_pts, thr_m5, f.buy_v, f.sell_v, f.reason, "M5");
   VoteSlope(m15_pts, thr_m15, f.buy_v, f.sell_v, f.reason, "M15");
   VoteSlope(h1_pts, thr_h1, f.buy_v, f.sell_v, f.reason, "H1");
   VoteSlope(f.m1_pts, thr_m1, f.buy_v, f.sell_v, f.reason, "M1");
   if(d_m5  > 0) f.buy_w += 1.5; else if(d_m5  < 0) f.sell_w += 1.5;
   if(d_m15 > 0) f.buy_w += 2.0; else if(d_m15 < 0) f.sell_w += 2.0;
   if(d_h1  > 0) f.buy_w += 2.5; else if(d_h1  < 0) f.sell_w += 2.5;
   if(d_m1  > 0) f.buy_w += 1.0; else if(d_m1  < 0) f.sell_w += 1.0;

   const int m5_now = FormingCandleDir(sym, PERIOD_M5, f.reason, "M5now");
   const int m15_now = FormingCandleDir(sym, PERIOD_M15, f.reason, "M15now");
   const int h1_now = FormingCandleDir(sym, PERIOD_H1, f.reason, "H1now");
   const int h1_cl = ClosedCandleDir(sym, PERIOD_H1, f.reason, "H1cl");
   if(m5_now > 0)  { f.buy_v++; f.buy_w += 1.2; } else if(m5_now < 0)  { f.sell_v++; f.sell_w += 1.2; }
   if(m15_now > 0) { f.buy_v++; f.buy_w += 1.6; } else if(m15_now < 0) { f.sell_v++; f.sell_w += 1.6; }
   if(h1_now > 0)  { f.buy_v++; f.buy_w += 2.0; } else if(h1_now < 0)  { f.sell_v++; f.sell_w += 2.0; }
   if(h1_cl > 0)   { f.buy_v++; f.buy_w += 3.0; } else if(h1_cl < 0)   { f.sell_v++; f.sell_w += 3.0; }

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
         if(bid > e[0] + dead)
           { f.buy_v++; f.buy_w += 1.5; above_ema = true; f.reason += "aboveEMA5 "; }
         else if(bid < e[0] - dead)
           { f.sell_v++; f.sell_w += 1.5; below_ema = true; f.reason += "belowEMA5 "; }
         else f.reason += "nearEMA5 ";
        }
      IndicatorRelease(ema);
     }

   // M1 fast impulse — тайминг
   if(m1_fast >= thr_m1 * 0.45)
     { f.reason += "M1f↑ "; f.buy_w += 0.8; }
   else if(m1_fast <= -thr_m1 * 0.45)
     { f.reason += "M1f↓ "; f.sell_w += 0.8; }

   f.reason += StringFormat("|M1=%.0f M5=%.0f M15=%.0f H1=%.0f", f.m1_pts, f.m5_pts, m15_pts, h1_pts);

   // Bias сразу (даже в шуме)
   if(f.buy_w > f.sell_w + 0.15)
      f.dir = ORDER_TYPE_BUY;
   else if(f.sell_w > f.buy_w + 0.15)
      f.dir = ORDER_TYPE_SELL;
   else
      f.dir = (f.m1_pts >= 0.0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   double total_w = f.buy_w + f.sell_w;
   if(total_w <= 0.01)
      f.conf = 0.0;
   else
      f.conf = 100.0 * MathAbs(f.buy_w - f.sell_w) / total_w;

   // Условия входа
   const bool m1_with_buy  = (f.m1_pts >= thr_m1 * 0.15 && m1_fast >= -thr_m1 * 0.50);
   const bool m1_with_sell = (f.m1_pts <= -thr_m1 * 0.15 && m1_fast <= thr_m1 * 0.50);

   const bool struct_buy =
      (h1_cl > 0 || h1_pts >= thr_h1 * 0.28 || h1_now > 0) &&
      (m5_now > 0 || f.m5_pts >= thr_m5 * 0.20 || m15_now > 0 || m15_pts > 0) &&
      (above_ema || m15_now > 0 || f.m5_pts > 0);
   const bool struct_sell =
      (h1_cl < 0 || h1_pts <= -thr_h1 * 0.28 || h1_now < 0) &&
      (m5_now < 0 || f.m5_pts <= -thr_m5 * 0.20 || m15_now < 0 || m15_pts < 0) &&
      (below_ema || m15_now < 0 || f.m5_pts < 0);

   const bool wick_blocks_buy  = (h1_now < 0 && h1_cl <= 0);
   const bool wick_blocks_sell = (h1_now > 0 && h1_cl >= 0);

   // Разбор для панели (сразу)
   const bool h1_up = (h1_cl > 0 || (h1_now > 0 && h1_cl >= 0));
   const bool h1_dn = (h1_cl < 0 || (h1_now < 0 && h1_cl <= 0));
   const bool m15_up = (m15_now > 0 || (m15_pts >= thr_m15 * 0.20 && m15_now >= 0));
   const bool m15_dn = (m15_now < 0 || (m15_pts <= -thr_m15 * 0.20 && m15_now <= 0));
   const bool m5_up = (m5_now > 0 || (f.m5_pts >= thr_m5 * 0.20 && m5_now >= 0));
   const bool m5_dn = (m5_now < 0 || (f.m5_pts <= -thr_m5 * 0.20 && m5_now <= 0));
   const bool m1_up = (m1_fast >= thr_m1 * 0.25 || (f.m1_pts >= thr_m1 * 0.20 && m1_fast >= 0));
   const bool m1_dn = (m1_fast <= -thr_m1 * 0.25 || (f.m1_pts <= -thr_m1 * 0.20 && m1_fast <= 0));

   f.analysis = StringFormat(
      "H1:%s M15:%s M5:%s M1:%s EMA5:%s | вес BUY %.1f / SELL %.1f",
      h1_up ? "↑" : (h1_dn ? "↓" : "="),
      m15_up ? "↑" : (m15_dn ? "↓" : "="),
      m5_up ? "↑" : (m5_dn ? "↓" : "="),
      m1_up ? "↑" : (m1_dn ? "↓" : "="),
      above_ema ? "выше" : (below_ema ? "ниже" : "около"),
      f.buy_w, f.sell_w);

   bool enter_buy =
      struct_buy && m1_with_buy && !wick_blocks_buy &&
      f.buy_w > f.sell_w + 0.8 && f.conf >= 32.0 && f.buy_v >= 3;
   bool enter_sell =
      struct_sell && m1_with_sell && !wick_blocks_sell &&
      f.sell_w > f.buy_w + 0.8 && f.conf >= 32.0 && f.sell_v >= 3;

   // Все ТФ в одну сторону — работаем по сигналу сразу
   const bool aligned_buy  = h1_up && m15_up && m5_up && m1_up && above_ema && !wick_blocks_buy;
   const bool aligned_sell = h1_dn && m15_dn && m5_dn && m1_dn && below_ema && !wick_blocks_sell;
   if(aligned_buy && f.buy_w >= f.sell_w)
     { enter_buy = true; f.conf = MathMax(f.conf, 60.0); }
   if(aligned_sell && f.sell_w >= f.buy_w)
     { enter_sell = true; f.conf = MathMax(f.conf, 60.0); }

   // Сильный bias без идеального M1 — мягкий вход
   if(!enter_buy && !enter_sell && f.conf >= 50.0)
     {
      if(f.dir == ORDER_TYPE_BUY && struct_buy && !wick_blocks_buy && m1_fast >= -thr_m1 * 0.8)
         enter_buy = true;
      if(f.dir == ORDER_TYPE_SELL && struct_sell && !wick_blocks_sell && m1_fast <= thr_m1 * 0.8)
         enter_sell = true;
     }

   if(enter_buy)
     {
      f.dir = ORDER_TYPE_BUY;
      f.clear = true;
      f.signal = SIG_BUY;
      f.reason = "QUALITY " + f.reason;
      f.signal_txt = StringFormat("СИГНАЛ: BUY %.0f%%  → ВХОД", f.conf);
     }
   else if(enter_sell)
     {
      f.dir = ORDER_TYPE_SELL;
      f.clear = true;
      f.signal = SIG_SELL;
      f.reason = "QUALITY " + f.reason;
      f.signal_txt = StringFormat("СИГНАЛ: SELL %.0f%%  → ВХОД", f.conf);
     }
   else
     {
      f.clear = false;
      f.signal = SIG_WAIT;
      string bias = (f.dir == ORDER_TYPE_BUY ? "BUY" : "SELL");
      f.signal_txt = StringFormat("СИГНАЛ: ЖДЁМ (bias %s %.0f%%)", bias, f.conf);
      f.reason = "CHOP " + f.reason;
      if(!m1_with_buy && !m1_with_sell)
         f.reason = "WAIT_M1 " + f.reason;
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
   // Баллы из весов — для панели BUY vs SELL
   s.buy  = f.buy_w * 10.0 + MathMax(0.0, f.m1_pts) / 25.0;
   s.sell = f.sell_w * 10.0 + MathMax(0.0, -f.m1_pts) / 25.0;
   s.reason = f.signal_txt + " | " + f.analysis + " | " + f.reason;
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
