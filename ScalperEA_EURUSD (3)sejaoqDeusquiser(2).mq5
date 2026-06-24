//+------------------------------------------------------------------+
//|                                          ScalperEA_EURUSD.mq5     |
//|  EA de Scalping para EUR/USD - M15                                |
//|                                                                     |
//|  Estratégia:                                                       |
//|   - Filtro de tendência: EMA(200)                                  |
//|   - Sinal de entrada: RSI(14) + Bandas de Bollinger(20,2)          |
//|     -> Compra: preço toca/fecha abaixo da banda inferior,          |
//|        RSI em sobrevenda, E preço acima da EMA200 (tendência alta) |
//|     -> Venda: preço toca/fecha acima da banda superior,            |
//|        RSI em sobrecompra, E preço abaixo da EMA200 (tendência     |
//|        baixa)                                                      |
//|   - SEM Stop Loss: a posição fica aberta até bater o Take Profit   |
//|     OU até completar o prazo máximo (InpMaxHoldDays), quando é     |
//|     fechada a mercado independente do resultado. RISCO SEM LIMITE  |
//|     DEFINIDO enquanto a posição estiver aberta.                    |
//|   - Take Profit dinâmico baseado em ATR (mantido)                  |
//|   - Lote calculado por % de risco do saldo da conta (apenas        |
//|     referência de dimensionamento, já que não há SL real)          |
//|   - Trailing stop baseado em ATR                                   |
//|   - Limite de perda diária (% do saldo) bloqueia novas entradas    |
//|   - Filtro de spread máximo                                        |
//|   - Bloqueio de nova operação enquanto houver posição aberta       |
//|     (substitui o antigo "1 trade por dia")                         |
//|   - Filtro de volatilidade: só opera se o ATR atual estiver acima  |
//|     de um % da média do ATR recente (evita mercado "morto")        |
//+----------------------------------------------------------------------+
#property copyright "Gerado com Claude"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//==================== INPUTS ====================

input group "=== Geral ==="
input ulong   InpMagicNumber        = 20260622;  // Número mágico (identifica trades deste EA)
input int     InpMaxPositions       = 1;         // Máximo de posições abertas simultâneas

input group "=== Indicadores ==="
input int     InpRSIPeriod          = 14;        // Período do RSI
input double  InpRSIOversold        = 30.0;      // Nível de sobrevenda do RSI
input double  InpRSIOverbought      = 70.0;      // Nível de sobrecompra do RSI
input int     InpBBPeriod           = 20;        // Período das Bandas de Bollinger
input double  InpBBDeviation        = 2.0;       // Desvio padrão das Bandas de Bollinger
input int     InpEMATrendPeriod     = 200;       // Período da EMA de tendência de fundo

input group "=== Take Profit (ATR) — SEM Stop Loss ==="
input int     InpATRPeriod          = 14;        // Período do ATR
input double  InpATR_SL_Multiplier  = 1.5;        // Multiplicador do ATR (usado só para dimensionar lote e TP, NÃO cria SL real)
input double  InpRiskReward         = 1.5;        // Relação Risco:Retorno (TP = referência_SL * este valor)

input group "=== Trailing Stop (ATR) ==="
input bool    InpUseTrailing        = true;       // Usar trailing stop?
input double  InpATR_TrailStart     = 1.0;        // Lucro em múltiplos de ATR para ativar o trailing
input double  InpATR_TrailStep      = 1.0;        // Distância do trailing em múltiplos de ATR

input group "=== Gestão de Risco ==="
input double  InpRiskPercent        = 7.0;        // % do saldo arriscado por operação
input double  InpDailyLossLimitPct  = 15.0;       // % máxima de perda diária (bloqueia novas entradas)

input group "=== Filtro de Spread ==="
input double  InpMaxSpreadPips      = 2.5;        // Spread máximo permitido (em pips) para nova entrada

input group "=== Filtro de Volatilidade (ATR) ==="
input bool    InpUseVolatilityFilter = true;       // Usar filtro de volatilidade?
input int     InpATR_VolatilityPeriod  = 50;       // Período da média do ATR para comparação
input double  InpATR_VolatilityMinRatio = 0.80;    // ATR atual deve ser >= este % da média (0.80 = 80%)

input group "=== Limite de Tempo da Posição ==="
input bool    InpUseMaxHoldTime    = true;        // Limitar tempo máximo que a posição pode ficar aberta?
input int     InpMaxHoldDays       = 30;          // Dias máximos com a posição aberta antes de fechar a mercado

//==================== VARIÁVEIS GLOBAIS ====================

int      hRSI, hBB, hEMA, hATR;
double   PipSize;          // tamanho do pip (considera contas de 5 e 3 dígitos)
datetime g_lastBarTime = 0;
double   g_dayStartBalance = 0.0;
int      g_currentDay = -1;
bool     g_dailyLimitHit = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   PipSize = (_Digits == 3 || _Digits == 5) ? _Point * 10.0 : _Point;

   hRSI = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   hBB  = iBands(_Symbol, PERIOD_M15, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hEMA = iMA(_Symbol, PERIOD_M15, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);

   if(hRSI == INVALID_HANDLE || hBB == INVALID_HANDLE || hEMA == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Erro ao criar handles dos indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   ResetDailyTracking();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hRSI);
   IndicatorRelease(hBB);
   IndicatorRelease(hEMA);
   IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
//| Reseta o controle de perda diária no início de um novo dia       |
//+------------------------------------------------------------------+
void ResetDailyTracking()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.day_of_year;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLimitHit = false;
  }

//+------------------------------------------------------------------+
//| Verifica se um novo dia começou e atualiza o controle de perda   |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_currentDay)
      ResetDailyTracking();
  }

//+------------------------------------------------------------------+
//| Verifica se o limite de perda diária foi atingido                |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
  {
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnlPercent = (currentBalance - g_dayStartBalance) / g_dayStartBalance * 100.0;

   if(pnlPercent <= -InpDailyLossLimitPct)
     {
      if(!g_dailyLimitHit)
         Print("Limite de perda diária atingido (", DoubleToString(pnlPercent,2), "%). Bloqueando novas entradas até o próximo dia.");
      g_dailyLimitHit = true;
     }

   return(g_dailyLimitHit);
  }

//+------------------------------------------------------------------+
//| Conta quantas posições deste EA/símbolo estão abertas             |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
        }
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Verifica se o spread atual está dentro do limite permitido       |
//+------------------------------------------------------------------+
bool IsSpreadOK()
  {
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips = spreadPoints * _Point / PipSize;
   return(spreadPips <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
//| Verifica se já existe posição aberta deste EA neste símbolo       |
//| (bloqueia nova entrada enquanto a atual não fechar)               |
//+------------------------------------------------------------------+
bool IsPositionOpen()
  {
   return(CountOpenPositions() > 0);
  }

//+------------------------------------------------------------------+
//| Fecha a mercado qualquer posição deste EA que tenha excedido o    |
//| prazo máximo definido em InpMaxHoldDays, independente do          |
//| resultado (lucro ou prejuízo)                                     |
//+------------------------------------------------------------------+
void CheckMaxHoldTime()
  {
   if(!InpUseMaxHoldTime)
      return;

   long maxHoldSeconds = (long)InpMaxHoldDays * 24 * 60 * 60;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;

      datetime openTime = (datetime)posInfo.Time();
      long heldSeconds = (long)(TimeCurrent() - openTime);

      if(heldSeconds >= maxHoldSeconds)
        {
         ulong ticket = posInfo.Ticket();
         Print("Posição #", ticket, " atingiu o prazo máximo de ", InpMaxHoldDays,
               " dias aberta. Fechando a mercado independente do resultado.");
         trade.PositionClose(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Verifica se o mercado está com volatilidade suficiente para       |
//| operar: ATR atual deve ser >= X% da média do ATR recente          |
//+------------------------------------------------------------------+
bool IsVolatilityOK()
  {
   if(!InpUseVolatilityFilter)
      return(true);

   double atrSeries[];
   ArraySetAsSeries(atrSeries, true);

   int barsNeeded = InpATR_VolatilityPeriod + 1;
   if(CopyBuffer(hATR, 0, 0, barsNeeded, atrSeries) < barsNeeded)
      return(false); // dados insuficientes -> não opera por segurança

   double atrCurrent = atrSeries[1]; // última vela fechada (mesmo índice usado no sinal)

   double sum = 0.0;
   for(int i = 1; i <= InpATR_VolatilityPeriod; i++)
      sum += atrSeries[i];
   double atrAverage = sum / InpATR_VolatilityPeriod;

   if(atrAverage <= 0)
      return(false);

   double ratio = atrCurrent / atrAverage;
   return(ratio >= InpATR_VolatilityMinRatio);
  }

//+------------------------------------------------------------------+
//| Calcula o tamanho do lote baseado no % de risco e na distância   |
//| do Stop Loss                                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || tickValue <= 0)
      return(0.0);

   double moneyPerPriceUnit = tickValue / tickSize;
   double lossPerLot = slDistancePrice * moneyPerPriceUnit;

   if(lossPerLot <= 0)
      return(0.0);

   double lots = riskAmount / lossPerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return(lots);
  }

//+------------------------------------------------------------------+
//| Gerencia o trailing stop das posições abertas deste EA           |
//+------------------------------------------------------------------+
void ManageTrailingStop(double atrValue)
  {
   if(!InpUseTrailing)
      return;

   double trailStartDist = atrValue * InpATR_TrailStart;
   double trailStepDist  = atrValue * InpATR_TrailStep;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDist = bid - openPrice;

         if(profitDist >= trailStartDist)
           {
            double newSL = bid - trailStepDist;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL > curSL || curSL == 0)
              {
               trade.PositionModify(ticket, newSL, curTP);
              }
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDist = openPrice - ask;

         if(profitDist >= trailStartDist)
           {
            double newSL = ask + trailStepDist;
            newSL = NormalizeDouble(newSL, _Digits);
            if(newSL < curSL || curSL == 0)
              {
               trade.PositionModify(ticket, newSL, curTP);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Função principal - executada em cada tick                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();

   // Fecha a mercado qualquer posição que tenha excedido o prazo máximo
   CheckMaxHoldTime();

   // Gerencia trailing stop a cada tick (não precisa esperar nova barra)
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 0, 1, atrBuf) > 0)
      ManageTrailingStop(atrBuf[0]);

   // O sinal de entrada só é avaliado uma vez por barra nova (M15)
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBarTime == g_lastBarTime)
      return;
   g_lastBarTime = currentBarTime;

   // Bloqueios para novas entradas
   if(IsDailyLossLimitHit())
      return;
   if(IsPositionOpen())
      return;
   if(!IsSpreadOK())
      return;
   if(CountOpenPositions() >= InpMaxPositions)
      return;
   if(!IsVolatilityOK())
      return;

   // Lê os indicadores na barra fechada anterior (índice 1)
   double rsiBuf[], bbUpperBuf[], bbLowerBuf[], emaBuf[];
   ArraySetAsSeries(rsiBuf, true);
   ArraySetAsSeries(bbUpperBuf, true);
   ArraySetAsSeries(bbLowerBuf, true);
   ArraySetAsSeries(emaBuf, true);

   if(CopyBuffer(hRSI, 0, 0, 3, rsiBuf) < 3) return;
   if(CopyBuffer(hBB, 1, 0, 3, bbUpperBuf) < 3) return; // banda superior
   if(CopyBuffer(hBB, 2, 0, 3, bbLowerBuf) < 3) return; // banda inferior
   if(CopyBuffer(hEMA, 0, 0, 3, emaBuf) < 3) return;
   if(CopyBuffer(hATR, 0, 0, 3, atrBuf) < 3) return;

   double closePrev = iClose(_Symbol, PERIOD_M15, 1);
   double rsiPrev   = rsiBuf[1];
   double bbUpPrev  = bbUpperBuf[1];
   double bbLowPrev = bbLowerBuf[1];
   double emaPrev   = emaBuf[1];
   double atrPrev   = atrBuf[1];

   bool isUptrend   = closePrev > emaPrev;
   bool isDowntrend = closePrev < emaPrev;

   bool buySignal  = isUptrend   && closePrev <= bbLowPrev && rsiPrev <= InpRSIOversold;
   bool sellSignal = isDowntrend && closePrev >= bbUpPrev  && rsiPrev >= InpRSIOverbought;

   if(buySignal)
      OpenPosition(ORDER_TYPE_BUY, atrPrev);
   else if(sellSignal)
      OpenPosition(ORDER_TYPE_SELL, atrPrev);
  }

//+------------------------------------------------------------------+
//| Abre uma posição com SL/TP calculados via ATR e lote via risco   |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue)
  {
   // ATENÇÃO: Esta versão do EA NÃO usa Stop Loss.
   // slDistance é usado apenas como referência para dimensionar o lote
   // e calcular o Take Profit — NÃO é enviado como SL real à corretora.
   // A posição só fecha via Take Profit ou via CheckMaxHoldTime()
   // (prazo máximo de InpMaxHoldDays). O risco de perda NÃO tem limite
   // definido enquanto a posição estiver aberta.
   double slDistance = atrValue * InpATR_SL_Multiplier;
   double tpDistance = slDistance * InpRiskReward;

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0)
     {
      Print("Lote calculado inválido, ordem não enviada.");
      return;
     }

   double price, tp;
   bool   sent = false;

   if(orderType == ORDER_TYPE_BUY)
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      tp = NormalizeDouble(price + tpDistance, _Digits);
      sent = trade.Buy(lots, _Symbol, price, 0, tp, "ScalperEA Buy");
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp = NormalizeDouble(price - tpDistance, _Digits);
      sent = trade.Sell(lots, _Symbol, price, 0, tp, "ScalperEA Sell");
     }

   if(sent)
      Print("Posição aberta SEM Stop Loss. Fechamento automático em até ", InpMaxHoldDays, " dias se o TP não for atingido.");
   else
      Print("Falha ao enviar ordem. Retcode: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
