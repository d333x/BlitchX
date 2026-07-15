//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
//|  v3.98: LTF cascade — вход через конфликт H1, если M15+M5+M1 жёстко |
//+------------------------------------------------------------------+
#ifndef CHART_KNOWLEDGE_MQH
#define CHART_KNOWLEDGE_MQH

enum ENUM_MARKET_SIGNAL
  {
   SIG_WAIT = 0,
   SIG_BUY  = 1,
   SIG_SELL = 2
  };

enum ENUM_OPP_SIZE
  {
   OPP_SMALL = 0,   // шум / мелкий ход — НЕ торгуем
   OPP_MID   = 1,   // средний — только если allow_mid
   OPP_BIG   = 2    // крупный — наша цель
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
   ENUM_ORDER_TYPE dir;
   string reason;
   ENUM_MARKET_SIGNAL signal;
   double buy_w;
   double sell_w;
   double conf;                  // 0..100
   string signal_txt;
   string analysis;
   // v3.95
   ENUM_OPP_SIZE opportunity;    // SMALL / MID / BIG
   double expected_usd;          // оценка хода в $ на текущий lot
   bool   aligned;               // все ТФ в одну сторону
   int    align_score;           // сколько ТФ за направление (0..5)
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
// Оценка потенциала хода в $ (contract/tick model; XAU: move × 100 × lot).
double EstimatePointsUsd(const string sym, const double pts, const double lot)
  {
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0 || lot <= 0.0) return 0.0;
   double price_move = MathAbs(pts) * point;

   // Самый точный путь для металлов/CFD: размер контракта
   double contract = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract > 0.0)
     {
      // XAU contract=100 → $1 хода × 100 × 0.05 lot = $5
      return price_move * contract * lot;
     }

   double tick_size = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size > 0.0 && tick_value > 0.0)
      return (price_move / tick_size) * tick_value * lot;

   string u = sym;
   StringToUpper(u);
   if(StringFind(u, "XAU") >= 0 || StringFind(u, "GOLD") >= 0)
      return price_move * 100.0 * lot;
   return price_move * 100000.0 * lot;
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
// Сколько из последних N закрытых свечей в сторону dir (+1 buy / -1 sell)
int ClosedRun(const string sym, const ENUM_TIMEFRAMES tf, const int bars, const int want_dir)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   int n = MathMax(bars, 1);
   if(CopyOpen(sym, tf, 1, n, o) < n) return 0;
   if(CopyClose(sym, tf, 1, n, c) < n) return 0;
   int hit = 0;
   for(int i = 0; i < n; i++)
     {
      int d = 0;
      if(c[i] > o[i]) d = 1;
      else if(c[i] < o[i]) d = -1;
      if(d == want_dir) hit++;
     }
   return hit;
  }

//+------------------------------------------------------------------+
// Ускорение: короткий наклон vs длинный (импульс «куда дальше»)
double ImpulseAccel(const string sym, const ENUM_TIMEFRAMES tf,
                    const int short_look, const int long_look)
  {
   double short_s = Pts(sym, CloseSlope(sym, tf, short_look));
   double long_s  = Pts(sym, CloseSlope(sym, tf, long_look));
   return short_s - long_s * 0.5;
  }

//+------------------------------------------------------------------+
// Мгновенный предикт: LTF = куда пойдёт сейчас; H1 = фильтр, не диктатор.
MarketFlow ReadMarketFlow(const string sym, const double lot_for_expect,
                          const double min_big_usd,
                          const double min_enter_conf)
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
   f.opportunity = OPP_SMALL;
   f.expected_usd = 0;
   f.aligned = false;
   f.align_score = 0;

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
   double m5_fast = Pts(sym, CloseSlope(sym, PERIOD_M5, 2));
   double acc_m1 = ImpulseAccel(sym, PERIOD_M1, 3, 8);
   double acc_m5 = ImpulseAccel(sym, PERIOD_M5, 2, 5);

   const int d_m5  = SlopeDir(f.m5_pts, thr_m5);
   const int d_m15 = SlopeDir(m15_pts, thr_m15);
   const int d_h1  = SlopeDir(h1_pts, thr_h1);
   const int d_m1  = SlopeDir(f.m1_pts, thr_m1);

   // --- Веса: ближний срок важнее для скальпа (деньги делаются на M1–M15) ---
   double micro_buy = 0, micro_sell = 0; // M1+M5+M15
   double macro_buy = 0, macro_sell = 0; // H1

   VoteSlope(f.m5_pts, thr_m5, f.buy_v, f.sell_v, f.reason, "M5");
   VoteSlope(m15_pts, thr_m15, f.buy_v, f.sell_v, f.reason, "M15");
   VoteSlope(h1_pts, thr_h1, f.buy_v, f.sell_v, f.reason, "H1");
   VoteSlope(f.m1_pts, thr_m1, f.buy_v, f.sell_v, f.reason, "M1");

   if(d_m1  > 0) micro_buy += 2.2; else if(d_m1  < 0) micro_sell += 2.2;
   if(d_m5  > 0) micro_buy += 2.8; else if(d_m5  < 0) micro_sell += 2.8;
   if(d_m15 > 0) micro_buy += 2.4; else if(d_m15 < 0) micro_sell += 2.4;
   if(d_h1  > 0) macro_buy += 1.6; else if(d_h1  < 0) macro_sell += 1.6; // H1 слабее!

   const int m5_now = FormingCandleDir(sym, PERIOD_M5, f.reason, "M5now");
   const int m15_now = FormingCandleDir(sym, PERIOD_M15, f.reason, "M15now");
   const int h1_now = FormingCandleDir(sym, PERIOD_H1, f.reason, "H1now");
   const int h1_cl = ClosedCandleDir(sym, PERIOD_H1, f.reason, "H1cl");
   const int m5_cl = ClosedCandleDir(sym, PERIOD_M5, f.reason, "M5cl");
   const int m15_cl = ClosedCandleDir(sym, PERIOD_M15, f.reason, "M15cl");

   if(m5_now > 0)  { f.buy_v++; micro_buy += 1.8; } else if(m5_now < 0)  { f.sell_v++; micro_sell += 1.8; }
   if(m15_now > 0) { f.buy_v++; micro_buy += 1.5; } else if(m15_now < 0) { f.sell_v++; micro_sell += 1.5; }
   if(m5_cl > 0)   { f.buy_v++; micro_buy += 1.4; } else if(m5_cl < 0)   { f.sell_v++; micro_sell += 1.4; }
   if(m15_cl > 0)  { f.buy_v++; micro_buy += 1.2; } else if(m15_cl < 0)  { f.sell_v++; micro_sell += 1.2; }
   // H1 cl/now — только лёгкий фильтр (раньше +3 ломало bias в BUY)
   if(h1_now > 0)  { f.buy_v++; macro_buy += 0.9; } else if(h1_now < 0)  { f.sell_v++; macro_sell += 0.9; }
   if(h1_cl > 0)   { f.buy_v++; macro_buy += 1.1; } else if(h1_cl < 0)   { f.sell_v++; macro_sell += 1.1; }

   // Серия закрытых M5 — предикт продолжения
   int run_up = ClosedRun(sym, PERIOD_M5, 3, 1);
   int run_dn = ClosedRun(sym, PERIOD_M5, 3, -1);
   if(run_up >= 2) { micro_buy += 1.3; f.reason += "runM5↑ "; }
   if(run_dn >= 2) { micro_sell += 1.3; f.reason += "runM5↓ "; }

   // Ускорение импульса
   if(acc_m1 > thr_m1 * 0.25) { micro_buy += 1.2; f.reason += "accM1↑ "; }
   else if(acc_m1 < -thr_m1 * 0.25) { micro_sell += 1.2; f.reason += "accM1↓ "; }
   if(acc_m5 > thr_m5 * 0.20) { micro_buy += 1.0; f.reason += "accM5↑ "; }
   else if(acc_m5 < -thr_m5 * 0.20) { micro_sell += 1.0; f.reason += "accM5↓ "; }

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
         // EMA лагает — малый вес; при конфликте с M1/M5 почти игнор
         if(bid > e[0] + dead)
           { above_ema = true; f.reason += "aboveEMA5 "; micro_buy += 0.6; }
         else if(bid < e[0] - dead)
           { below_ema = true; f.reason += "belowEMA5 "; micro_sell += 0.6; }
         else f.reason += "nearEMA5 ";
        }
      IndicatorRelease(ema);
     }

   if(m1_fast >= thr_m1 * 0.45)
     { f.reason += "M1f↑ "; micro_buy += 1.1; }
   else if(m1_fast <= -thr_m1 * 0.45)
     { f.reason += "M1f↓ "; micro_sell += 1.1; }

   if(m5_fast >= thr_m5 * 0.35)
     { micro_buy += 0.8; }
   else if(m5_fast <= -thr_m5 * 0.35)
     { micro_sell += 0.8; }

   f.buy_w = micro_buy + macro_buy;
   f.sell_w = micro_sell + macro_sell;
   f.reason += StringFormat("|μB%.1f/S%.1f H1B%.1f/S%.1f |M1=%.0f M5=%.0f M15=%.0f H1=%.0f",
                            micro_buy, micro_sell, macro_buy, macro_sell,
                            f.m1_pts, f.m5_pts, m15_pts, h1_pts);

   // Направление для СКАЛЬПА = микро-поток (куда пойдёт ближайшие минуты)
   ENUM_ORDER_TYPE micro_dir = ORDER_TYPE_BUY;
   if(micro_sell > micro_buy + 0.2)
      micro_dir = ORDER_TYPE_SELL;
   else if(micro_buy > micro_sell + 0.2)
      micro_dir = ORDER_TYPE_BUY;
   else
      micro_dir = (m1_fast >= 0.0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   ENUM_ORDER_TYPE macro_dir = ORDER_TYPE_BUY;
   if(macro_sell > macro_buy + 0.1)
      macro_dir = ORDER_TYPE_SELL;
   else if(macro_buy > macro_sell + 0.1)
      macro_dir = ORDER_TYPE_BUY;
   else
      macro_dir = (h1_pts >= 0.0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   const bool conflict = (micro_dir != macro_dir);
   // Bias на экране = прогноз ближайшего хода (микро), не «залипший» H1 BUY
   f.dir = micro_dir;

   double micro_tot = micro_buy + micro_sell;
   if(micro_tot <= 0.01)
      f.conf = 0.0;
   else
      f.conf = 100.0 * MathAbs(micro_buy - micro_sell) / micro_tot;
   // Конфликт H1 vs LTF: штраф отложим — после cascade (сильный LTF не режем в 49%)

   const bool m1_with_buy  = (f.m1_pts >= thr_m1 * 0.15 && m1_fast >= -thr_m1 * 0.25);
   const bool m1_with_sell = (f.m1_pts <= -thr_m1 * 0.15 && m1_fast <= thr_m1 * 0.25);

   // Структура: LTF обязательны; сильный микро может идти против H1 (cascade)
   const bool struct_buy =
      (m5_now > 0 || f.m5_pts >= thr_m5 * 0.20 || m15_now > 0 || m5_cl > 0) &&
      (m15_pts > -thr_m15 * 0.15 || m15_now > 0 || m15_cl > 0) &&
      (macro_dir == ORDER_TYPE_BUY || micro_buy > micro_sell + 3.0);
   const bool struct_sell =
      (m5_now < 0 || f.m5_pts <= -thr_m5 * 0.20 || m15_now < 0 || m5_cl < 0) &&
      (m15_pts < thr_m15 * 0.15 || m15_now < 0 || m15_cl < 0) &&
      (macro_dir == ORDER_TYPE_SELL || micro_sell > micro_buy + 3.0);

   // Блок: свеча H1 против при слабом микро
   const bool wick_blocks_buy  = (h1_now < 0 && h1_cl < 0 && micro_buy < micro_sell + 2.0);
   const bool wick_blocks_sell = (h1_now > 0 && h1_cl > 0 && micro_sell < micro_buy + 2.0);

   const bool h1_up = (h1_cl > 0 || (h1_now > 0 && h1_cl >= 0) || h1_pts >= thr_h1 * 0.2);
   const bool h1_dn = (h1_cl < 0 || (h1_now < 0 && h1_cl <= 0) || h1_pts <= -thr_h1 * 0.2);
   const bool m15_up = (m15_now > 0 || m15_cl > 0 || (m15_pts >= thr_m15 * 0.20 && m15_now >= 0));
   const bool m15_dn = (m15_now < 0 || m15_cl < 0 || (m15_pts <= -thr_m15 * 0.20 && m15_now <= 0));
   const bool m5_up = (m5_now > 0 || m5_cl > 0 || (f.m5_pts >= thr_m5 * 0.20 && m5_now >= 0));
   const bool m5_dn = (m5_now < 0 || m5_cl < 0 || (f.m5_pts <= -thr_m5 * 0.20 && m5_now <= 0));
   const bool m1_up = (m1_fast >= thr_m1 * 0.25 || (f.m1_pts >= thr_m1 * 0.20 && m1_fast >= 0));
   const bool m1_dn = (m1_fast <= -thr_m1 * 0.25 || (f.m1_pts <= -thr_m1 * 0.20 && m1_fast <= 0));

   double atr_use = atr_m5 * 1.0 + atr_m15 * 0.35;
   if(atr_h1 > atr_m15 * 2.2)
      atr_use *= 1.20;
   f.expected_usd = EstimatePointsUsd(sym, atr_use, lot_for_expect);

   // Align считаем относительно ПРОГНОЗА (микро-dir)
   if(f.dir == ORDER_TYPE_BUY)
     {
      if(h1_up) f.align_score++;
      if(m15_up) f.align_score++;
      if(m5_up) f.align_score++;
      if(m1_up) f.align_score++;
      if(above_ema && !m5_dn) f.align_score++; // EMA не плюсуем, если M5 уже ↓
     }
   else
     {
      if(h1_dn) f.align_score++;
      if(m15_dn) f.align_score++;
      if(m5_dn) f.align_score++;
      if(m1_dn) f.align_score++;
      if(below_ema && !m5_up) f.align_score++;
     }

   // Полное выравнивание: 3 LTF + микро; H1 не обязателен при сильном cascade
   const bool ltf_buy  = m15_up && m5_up && m1_up;
   const bool ltf_sell = m15_dn && m5_dn && m1_dn;
   const double micro_gap = MathAbs(micro_buy - micro_sell);
   // Hard cascade: как у юзера — μ SELL 18 / BUY 1, EMA ниже, все LTF↓, H1↑
   const bool strong_sell_ltf =
      (ltf_sell && micro_sell >= micro_buy + 4.0 &&
       (below_ema || micro_gap >= 6.0) && m1_with_sell && !wick_blocks_sell);
   const bool strong_buy_ltf =
      (ltf_buy && micro_buy >= micro_sell + 4.0 &&
       (above_ema || micro_gap >= 6.0) && m1_with_buy && !wick_blocks_buy);

   // Конфликт: мягкий штраф, НО не режем conf в 49%, если LTF cascade жёсткий
   if(conflict && !(strong_sell_ltf || strong_buy_ltf))
     {
      f.conf *= 0.70;
      f.conf = MathMax(8.0, MathMin(72.0, f.conf));
     }
   else if(strong_sell_ltf || strong_buy_ltf)
     {
      f.conf = MathMax(f.conf, min_enter_conf);
      if(conflict)
         f.conf = MathMax(f.conf, min_enter_conf + 2.0);
     }

   const bool aligned_buy  = ltf_buy && (h1_up || !conflict || strong_buy_ltf) && m1_with_buy && !wick_blocks_buy;
   const bool aligned_sell = ltf_sell && (h1_dn || !conflict || strong_sell_ltf) && m1_with_sell && !wick_blocks_sell;
   f.aligned = (aligned_buy || aligned_sell);

   const bool money_big = (f.expected_usd >= min_big_usd);
   const bool money_mid = (f.expected_usd >= min_big_usd * 0.55);
   const bool conf_big  = (f.conf >= min_enter_conf);
   const bool conf_mid  = (f.conf >= min_enter_conf * 0.85);
   const bool weight_gap = (micro_gap >= 3.5);

   // BIG: либо чистое выравнивание, либо hard LTF cascade поверх H1-конфликта
   if(strong_sell_ltf || strong_buy_ltf)
      f.opportunity = (money_mid ? OPP_BIG : OPP_MID);
   else if(conflict)
      f.opportunity = (money_mid && conf_mid && f.align_score >= 3) ? OPP_MID : OPP_SMALL;
   else if(money_big && conf_big && f.align_score >= 4 && weight_gap)
      f.opportunity = OPP_BIG;
   else if(f.aligned && money_mid && conf_mid && f.align_score >= 4)
      f.opportunity = OPP_BIG;
   else if(ltf_buy && f.dir == ORDER_TYPE_BUY && money_mid && f.conf >= min_enter_conf * 0.90 && weight_gap)
      f.opportunity = OPP_BIG;
   else if(ltf_sell && f.dir == ORDER_TYPE_SELL && money_mid && f.conf >= min_enter_conf * 0.90 && weight_gap)
      f.opportunity = OPP_BIG;
   else if(f.align_score >= 5 && f.conf >= min_enter_conf * 0.90 && money_mid)
      f.opportunity = OPP_BIG;
   else if(money_mid && conf_mid && f.align_score >= 3)
      f.opportunity = OPP_MID;
   else
      f.opportunity = OPP_SMALL;

   string opp_tag = (f.opportunity == OPP_BIG ? "КРУПНЫЙ"
                     : (f.opportunity == OPP_MID ? "СРЕДНИЙ" : "МЕЛКИЙ"));
   string forecast = (f.dir == ORDER_TYPE_BUY ? "BUY" : "SELL");
   if(conflict && !(strong_sell_ltf || strong_buy_ltf))
      forecast = StringFormat("%s≠H1", forecast);
   else if(conflict)
      forecast = StringFormat("%s·cas", forecast);

   f.analysis = StringFormat(
      "H1:%s M15:%s M5:%s M1:%s EMA:%s | μ BUY %.1f/SELL %.1f | %s ~$%.0f align=%d%s",
      h1_up ? "↑" : (h1_dn ? "↓" : "="),
      m15_up ? "↑" : (m15_dn ? "↓" : "="),
      m5_up ? "↑" : (m5_dn ? "↓" : "="),
      m1_up ? "↑" : (m1_dn ? "↓" : "="),
      above_ema ? "выше" : (below_ema ? "ниже" : "около"),
      micro_buy, micro_sell, opp_tag, f.expected_usd, f.align_score,
      conflict ? (strong_sell_ltf || strong_buy_ltf ? " CASCADE" : " КОНФЛИКТ") : "");

   bool enter_buy = false;
   bool enter_sell = false;

   // Обычный BIG без конфликта
   if(f.opportunity == OPP_BIG && !conflict)
     {
      if(f.dir == ORDER_TYPE_BUY && struct_buy && m1_with_buy && !wick_blocks_buy &&
         micro_buy > micro_sell + 1.5 && f.align_score >= 4)
         enter_buy = true;
      if(f.dir == ORDER_TYPE_SELL && struct_sell && m1_with_sell && !wick_blocks_sell &&
         micro_sell > micro_buy + 1.5 && f.align_score >= 4)
         enter_sell = true;
      if(aligned_buy && micro_buy >= micro_sell)
        { enter_buy = true; f.conf = MathMax(f.conf, min_enter_conf); }
      if(aligned_sell && micro_sell >= micro_buy)
        { enter_sell = true; f.conf = MathMax(f.conf, min_enter_conf); }
     }

   // v3.98 CASCADE: H1 против, но M15+M5+M1 + μ разрыв → ВХОД (как шорт «на глаз»)
   if(f.opportunity == OPP_BIG && money_mid)
     {
      if(strong_sell_ltf && f.dir == ORDER_TYPE_SELL && struct_sell)
        {
         enter_sell = true;
         f.conf = MathMax(f.conf, min_enter_conf);
         f.reason = "CASCADE_SELL " + f.reason;
        }
      if(strong_buy_ltf && f.dir == ORDER_TYPE_BUY && struct_buy)
        {
         enter_buy = true;
         f.conf = MathMax(f.conf, min_enter_conf);
         f.reason = "CASCADE_BUY " + f.reason;
        }
     }

   if(enter_buy)
     {
      f.dir = ORDER_TYPE_BUY;
      f.clear = true;
      f.signal = SIG_BUY;
      f.reason = "PRED_BUY " + f.reason;
      f.signal_txt = StringFormat("СИГНАЛ: BUY %.0f%% КРУПНЫЙ ~$%.0f → ВХОД", f.conf, f.expected_usd);
     }
   else if(enter_sell)
     {
      f.dir = ORDER_TYPE_SELL;
      f.clear = true;
      f.signal = SIG_SELL;
      f.reason = "PRED_SELL " + f.reason;
      f.signal_txt = StringFormat("СИГНАЛ: SELL %.0f%% КРУПНЫЙ ~$%.0f → ВХОД", f.conf, f.expected_usd);
     }
   else
     {
      f.clear = false;
      f.signal = SIG_WAIT;
      if(f.opportunity == OPP_SMALL)
         f.signal_txt = StringFormat("ЖДЁМ %s %.0f%% · МЕЛКИЙ ~$%.0f", forecast, f.conf, f.expected_usd);
      else if(f.opportunity == OPP_MID)
         f.signal_txt = StringFormat("ЖДЁМ %s %.0f%% · СРЕДНИЙ ~$%.0f", forecast, f.conf, f.expected_usd);
      else
         f.signal_txt = StringFormat("ЖДЁМ %s %.0f%% · КРУПНЫЙ не готов ~$%.0f", forecast, f.conf, f.expected_usd);
      f.reason = "FILTER_" + opp_tag + (conflict ? "_CONFLICT " : " ") + f.reason;
     }

   return f;
  }

// Backward-compatible overload
MarketFlow ReadMarketFlow(const string sym)
  {
   return ReadMarketFlow(sym, 0.05, 8.0, 72.0);
  }

//+------------------------------------------------------------------+
KnowledgeScore EvaluateKnowledge(const string sym,
                                 const ENUM_TIMEFRAMES /*signal_tf*/,
                                 const bool /*trend_up*/,
                                 const bool /*trend_down*/)
  {
   MarketFlow f = ReadMarketFlow(sym);
   KnowledgeScore s;
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
