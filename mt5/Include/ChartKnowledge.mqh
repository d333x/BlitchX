//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
//|  База знаний: свечи, структура, импульс → score BUY/SELL         |
 //+------------------------------------------------------------------+
#ifndef CHART_KNOWLEDGE_MQH
#define CHART_KNOWLEDGE_MQH

// Анатомия свечи i (относительно ArraySetAsSeries / Copy... series)
struct CandleFacts
  {
   double o, h, l, c;
   double body;
   double range;
   double upper;
   double lower;
   double body_ratio;   // body/range
   double close_loc;    // 0=low .. 1=high
   bool   bull;
   bool   bear;
   bool   doji;
  };

struct KnowledgeScore
  {
   int    buy;
   int    sell;
   string reason;
  };

//+------------------------------------------------------------------+
bool FillCandle(const string sym, const ENUM_TIMEFRAMES tf, const int shift, CandleFacts &f)
  {
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(sym, tf, shift, 1, o) < 1) return false;
   if(CopyHigh(sym, tf, shift, 1, h) < 1) return false;
   if(CopyLow(sym, tf, shift, 1, l) < 1) return false;
   if(CopyClose(sym, tf, shift, 1, c) < 1) return false;

   f.o = o[0]; f.h = h[0]; f.l = l[0]; f.c = c[0];
   f.body  = MathAbs(f.c - f.o);
   f.range = f.h - f.l;
   if(f.range <= 0.0) f.range = SymbolInfoDouble(sym, SYMBOL_POINT);
   f.upper = f.h - MathMax(f.o, f.c);
   f.lower = MathMin(f.o, f.c) - f.l;
   f.body_ratio = f.body / f.range;
   f.close_loc  = (f.c - f.l) / f.range;
   f.bull = (f.c > f.o);
   f.bear = (f.c < f.o);
   f.doji = (f.body_ratio < 0.12);
   return true;
  }

//+------------------------------------------------------------------+
bool IsHammer(const CandleFacts &f)
  {
   // молот / пин вверх: длинная нижняя тень, тело в верхней трети
   return (f.lower >= 2.0 * f.body && f.upper <= f.body && f.close_loc >= 0.60);
  }

//+------------------------------------------------------------------+
bool IsShootingStar(const CandleFacts &f)
  {
   return (f.upper >= 2.0 * f.body && f.lower <= f.body && f.close_loc <= 0.40);
  }

//+------------------------------------------------------------------+
bool IsBullEngulf(const CandleFacts &prev, const CandleFacts &cur)
  {
   return (prev.bear && cur.bull &&
           cur.o <= prev.c && cur.c >= prev.o &&
           cur.body > prev.body);
  }

//+------------------------------------------------------------------+
bool IsBearEngulf(const CandleFacts &prev, const CandleFacts &cur)
  {
   return (prev.bull && cur.bear &&
           cur.o >= prev.c && cur.c <= prev.o &&
           cur.body > prev.body);
  }

//+------------------------------------------------------------------+
bool IsInsideBar(const CandleFacts &prev, const CandleFacts &cur)
  {
   return (cur.h <= prev.h && cur.l >= prev.l);
  }

//+------------------------------------------------------------------+
bool StructureBull(const string sym, const ENUM_TIMEFRAMES tf)
  {
   // HH + HL на последних закрытых пиках/впадинах (упрощённо по 3 свечам)
   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(sym, tf, 1, 6, h) < 6) return false;
   if(CopyLow(sym, tf, 1, 6, l) < 6) return false;
   // недавний swing high выше предыдущего, swing low выше предыдущего
   double hh_recent = MathMax(h[0], h[1]);
   double hh_older  = MathMax(h[3], h[4]);
   double ll_recent = MathMin(l[0], l[1]);
   double ll_older  = MathMin(l[3], l[4]);
   return (hh_recent > hh_older && ll_recent > ll_older);
  }

//+------------------------------------------------------------------+
bool StructureBear(const string sym, const ENUM_TIMEFRAMES tf)
  {
   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(sym, tf, 1, 6, h) < 6) return false;
   if(CopyLow(sym, tf, 1, 6, l) < 6) return false;
   double hh_recent = MathMax(h[0], h[1]);
   double hh_older  = MathMax(h[3], h[4]);
   double ll_recent = MathMin(l[0], l[1]);
   double ll_older  = MathMin(l[3], l[4]);
   return (hh_recent < hh_older && ll_recent < ll_older);
  }

//+------------------------------------------------------------------+
bool ThreeSoldiers(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a)) return false;
   if(!FillCandle(sym, tf, 2, b)) return false;
   if(!FillCandle(sym, tf, 1, c)) return false;
   return (a.bull && b.bull && c.bull && b.c > a.c && c.c > b.c &&
           a.body_ratio > 0.45 && b.body_ratio > 0.45 && c.body_ratio > 0.45);
  }

//+------------------------------------------------------------------+
bool ThreeCrows(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a)) return false;
   if(!FillCandle(sym, tf, 2, b)) return false;
   if(!FillCandle(sym, tf, 1, c)) return false;
   return (a.bear && b.bear && c.bear && b.c < a.c && c.c < b.c &&
           a.body_ratio > 0.45 && b.body_ratio > 0.45 && c.body_ratio > 0.45);
  }

//+------------------------------------------------------------------+
bool MorningStarLike(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a)) return false;
   if(!FillCandle(sym, tf, 2, b)) return false;
   if(!FillCandle(sym, tf, 1, c)) return false;
   return (a.bear && a.body_ratio > 0.5 &&
           b.body_ratio < 0.30 &&
           c.bull && c.body_ratio > 0.45 && c.c > (a.o + a.c) * 0.5);
  }

//+------------------------------------------------------------------+
bool EveningStarLike(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a)) return false;
   if(!FillCandle(sym, tf, 2, b)) return false;
   if(!FillCandle(sym, tf, 1, c)) return false;
   return (a.bull && a.body_ratio > 0.5 &&
           b.body_ratio < 0.30 &&
           c.bear && c.body_ratio > 0.45 && c.c < (a.o + a.c) * 0.5);
  }

//+------------------------------------------------------------------+
// Главная оценка базы знаний для символа
KnowledgeScore EvaluateKnowledge(const string sym,
                                 const ENUM_TIMEFRAMES signal_tf,
                                 const bool trend_up,
                                 const bool trend_down)
  {
   KnowledgeScore s;
   s.buy = 0; s.sell = 0; s.reason = "";

   CandleFacts cur, prev;
   if(!FillCandle(sym, signal_tf, 1, cur) || !FillCandle(sym, signal_tf, 2, prev))
     {
      s.reason = "no candles";
      return s;
     }

   // --- тренд EMA голос ---
   if(trend_up)  { s.buy += 3;  s.reason += "EMA↑ "; }
   if(trend_down){ s.sell += 3; s.reason += "EMA↓ "; }

   // --- импульс закрытия ---
   if(cur.bull && cur.close_loc >= 0.70 && cur.body_ratio >= 0.50)
     { s.buy += 2; s.reason += "impulse↑ "; }
   if(cur.bear && cur.close_loc <= 0.30 && cur.body_ratio >= 0.50)
     { s.sell += 2; s.reason += "impulse↓ "; }

   // --- пин / молот / звезда ---
   if(IsHammer(cur))
     { s.buy += 3; s.reason += "hammer "; }
   if(IsShootingStar(cur))
     { s.sell += 3; s.reason += "shootStar "; }

   // --- поглощение ---
   if(IsBullEngulf(prev, cur))
     { s.buy += 4; s.reason += "bullEngulf "; }
   if(IsBearEngulf(prev, cur))
     { s.sell += 4; s.reason += "bearEngulf "; }

   // --- звёзды ---
   if(MorningStarLike(sym, signal_tf))
     { s.buy += 3; s.reason += "morningStar "; }
   if(EveningStarLike(sym, signal_tf))
     { s.sell += 3; s.reason += "eveningStar "; }

   // --- три солдата / ворона ---
   if(ThreeSoldiers(sym, signal_tf))
     { s.buy += 4; s.reason += "3soldiers "; }
   if(ThreeCrows(sym, signal_tf))
     { s.sell += 4; s.reason += "3crows "; }

   // --- структура рынка ---
   if(StructureBull(sym, signal_tf))
     { s.buy += 2; s.reason += "HH/HL "; }
   if(StructureBear(sym, signal_tf))
     { s.sell += 2; s.reason += "LH/LL "; }

   // --- doji / inside: штраф за уверенность (не блокирует) ---
   if(cur.doji)
     {
      // уменьшаем обе стороны, чтобы чаще брали last dir / ждали
      if(s.buy > 0)  s.buy  = MathMax(0, s.buy - 1);
      if(s.sell > 0) s.sell = MathMax(0, s.sell - 1);
      s.reason += "doji ";
     }
   if(IsInsideBar(prev, cur))
     {
      s.reason += "inside ";
     }

   if(s.reason == "")
      s.reason = "flat";
   return s;
  }

//+------------------------------------------------------------------+
// Выбор стороны по базе знаний. gap = минимальный отрыв buy vs sell.
bool KnowledgePickDir(const KnowledgeScore &ks, const int gap,
                      ENUM_ORDER_TYPE &type, string &reason)
  {
   int diff = ks.buy - ks.sell;
   if(diff >= gap)
     {
      type = ORDER_TYPE_BUY;
      reason = StringFormat("KB BUY(%d/%d) %s", ks.buy, ks.sell, ks.reason);
      return true;
     }
   if(-diff >= gap)
     {
      type = ORDER_TYPE_SELL;
      reason = StringFormat("KB SELL(%d/%d) %s", ks.buy, ks.sell, ks.reason);
      return true;
     }
   return false;
  }

#endif // CHART_KNOWLEDGE_MQH
//+------------------------------------------------------------------+
