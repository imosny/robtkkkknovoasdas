//+------------------------------------------------------------------+
//|                                          ScalperEA_XAUUSD.mq5     |
//|  EA para XAUUSD (Ouro/Dólar) - M5/M15                             |
//|                                                                     |
//|  Estratégia:                                                       |
//|   - Filtro de tendência: EMA(200)                                  |
//|   - Filtro de força de tendência: ADX(14) >= limiar                |
//|   - Sinal de entrada: Breakout do high/low das últimas N velas     |
//|     -> Compra: fecha acima do maior high do range anterior,        |
//|        preço acima da EMA200, ADX >= limiar                        |
//|     -> Venda: fecha abaixo do menor low do range anterior,         |
//|        preço abaixo da EMA200, ADX >= limiar                       |
//|   - Filtro de sessão: só opera dentro da janela de horário          |
//|     configurada (padrão: sobreposição Londres/NY)                  |
//|   - SEM Stop Loss real: a posição fica aberta até:                 |
//|       1) bater o Take Profit (lucro), OU                           |
//|       2) o preço voltar ao preço de entrada (breakeven antecipado),|
//|          OU                                                        |
//|       3) completar o prazo máximo (InpMaxHoldDays), quando é       |
//|          fechada a mercado independente do resultado.              |
//|     RISCO SEM LIMITE DEFINIDO enquanto a posição estiver aberta.   |
//|   - Take Profit dinâmico baseado em ATR                            |
//|   - Lote calculado por % de risco do saldo da conta (apenas        |
//|     referência de dimensionamento, já que não há SL real)          |
//|   - Trailing stop baseado em ATR                                   |
//|   - Limite de perda diária (% do saldo) bloqueia novas entradas    |
//|   - Filtro de spread máximo (em pontos, adequado ao XAUUSD)        |
//|   - Filtro de volatilidade: só opera se o ATR atual estiver acima  |
//|     de um % da média do ATR recente (evita mercado "morto")        |
//|   - Bloqueio de nova operação enquanto houver posição aberta       |
//|     (1 posição por vez; pode levar até InpMaxHoldDays entre        |
//|     operações se a anterior não fechar antes)                      |
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
input ulong   InpMagicNumber        = 20260624;  // Número mágico (identifica trades deste EA)
input int     InpMaxPositions       = 1;         // Máximo de posições abertas simultâneas

input group "=== Indicadores de Tendência ==="
input int     InpEMATrendPeriod     = 200;       // Período da EMA de tendência de fundo
input int     InpADXPeriod          = 14;        // Período do ADX
input double  InpADXMinLevel        = 30.0;      // Nível mínimo de ADX para confirmar tendência (libera entrada)

input group "=== Entrada por Breakout ==="
input int     InpBreakoutBars       = 30;        // Quantidade de velas anteriores para definir o range (high/low)

input group "=== Take Profit (ATR) — SEM Stop Loss ==="
input int     InpATRPeriod          = 14;        // Período do ATR
input double  InpATR_SL_Multiplier  = 1.5;       // Multiplicador do ATR (usado só para dimensionar lote e TP, NÃO cria SL real)
input double  InpRiskReward         = 1.5;       // Relação Risco:Retorno (TP = referência_SL * este valor)

input group "=== Trailing Stop (ATR) ==="
input bool    InpUseTrailing        = true;      // Usar trailing stop?
input double  InpATR_TrailStart     = 1.0;       // Lucro em múltiplos de ATR para ativar o trailing
input double  InpATR_TrailStep      = 1.0;       // Distância do trailing em múltiplos de ATR

input group "=== Gestão de Risco ==="
input double  InpRiskPercent        = 7.0;       // % do saldo arriscado por operação
input double  InpDailyLossLimitPct  = 15.0;      // % máxima de perda diária (bloqueia novas entradas)

input group "=== Filtro de Spread ==="
input double  InpMaxSpreadPoints    = 350;       // Spread máximo permitido (em pontos) para nova entrada

input group "=== Filtro de Volatilidade (ATR) ==="
input bool    InpUseVolatilityFilter   = true;   // Usar filtro de volatilidade?
input int     InpATR_VolatilityPeriod  = 50;     // Período da média do ATR para comparação
input double  InpATR_VolatilityMinRatio = 0.80;  // ATR atual deve ser >= este % da média (0.80 = 80%)

input group "=== Filtro de Sessão (horário do servidor) ==="
input bool    InpUseSessionFilter   = true;      // Usar filtro de janela de horário?
input int     InpSessionStartHour   = 13;        // Hora de início da sessão permitida (horário do servidor)
input int     InpSessionEndHour     = 17;        // Hora de fim da sessão permitida (horário do servidor)

input group "=== Gestão de Posição / Prazo Máximo ==="
input bool    InpUseMaxHoldTime     = true;      // Limitar tempo máximo que a posição pode ficar aberta?
input int     InpMaxHoldDays        = 7;         // Dias máximos com a posição aberta antes de fechar a mercado
input bool    InpUseBreakeven       = true;       // Fechar antecipadamente se o preço voltar ao preço de entrada?

//==================== VARIÁVEIS GLOBAIS ====================

int      hEMA, hADX, hATR;
datetime g_lastBarTime = 0;
double   g_dayStartBalance = 0.0;
int      g_currentDay = -1;
bool     g_dailyLimitHit = false;

// Controle de "já esteve em lucro" por posição, necessário para o
// breakeven antecipado: só fecha no breakeven se a posição já chegou
// a ficar positiva e depois recuou até o preço de entrada (evita
// fechar a posição logo na abertura por flutuação normal de spread).
#define MAX_TRACKED_POSITIONS 20
ulong    g_trackedTickets[MAX_TRACKED_POSITIONS];
bool     g_wasProfitable[MAX_TRACKED_POSITIONS];
int      g_trackedCount = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   hEMA = iMA(_Symbol, PERIOD_CURRENT, InpEMATrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(hEMA == INVALID_HANDLE || hADX == INVALID_HANDLE || hATR == INVALID_HANDLE)
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
   IndicatorRelease(hEMA);
   IndicatorRelease(hADX);
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
//| (em pontos, adequado ao XAUUSD)                                   |
//+------------------------------------------------------------------+
bool IsSpreadOK()
  {
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spreadPoints <= InpMaxSpreadPoints);
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
//| Verifica se o horário atual está dentro da janela de sessão       |
//| permitida (horário do servidor da corretora)                      |
//+------------------------------------------------------------------+
bool IsSessionOK()
  {
   if(!InpUseSessionFilter)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   if(InpSessionStartHour <= InpSessionEndHour)
      return(hour >= InpSessionStartHour && hour < InpSessionEndHour);
   else
      // janela que cruza a meia-noite (ex: 22h às 3h)
      return(hour >= InpSessionStartHour || hour < InpSessionEndHour);
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
//| Calcula o maior high e o menor low das últimas N velas fechadas  |
//| (índices 1 até InpBreakoutBars, ou seja, exclui a vela atual)     |
//+------------------------------------------------------------------+
bool GetBreakoutRange(double &rangeHigh, double &rangeLow)
  {
   double highBuf[], lowBuf[];
   ArraySetAsSeries(highBuf, true);
   ArraySetAsSeries(lowBuf, true);

   int copiedHigh = CopyHigh(_Symbol, PERIOD_CURRENT, 1, InpBreakoutBars, highBuf);
   int copiedLow  = CopyLow(_Symbol, PERIOD_CURRENT, 1, InpBreakoutBars, lowBuf);

   if(copiedHigh < InpBreakoutBars || copiedLow < InpBreakoutBars)
      return(false);

   rangeHigh = highBuf[ArrayMaximum(highBuf)];
   rangeLow  = lowBuf[ArrayMinimum(lowBuf)];

   return(true);
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
//| Procura o índice de rastreamento de um ticket; retorna -1 se não  |
//| encontrado                                                         |
//+------------------------------------------------------------------+
int FindTrackedIndex(ulong ticket)
  {
   for(int i = 0; i < g_trackedCount; i++)
      if(g_trackedTickets[i] == ticket)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Registra um novo ticket no rastreamento de lucro (chamado quando  |
//| uma posição nova é detectada)                                     |
//+------------------------------------------------------------------+
void TrackNewPosition(ulong ticket)
  {
   if(FindTrackedIndex(ticket) >= 0)
      return; // já rastreado
   if(g_trackedCount >= MAX_TRACKED_POSITIONS)
      return; // capacidade máxima (não deve ocorrer com InpMaxPositions baixo)

   g_trackedTickets[g_trackedCount]  = ticket;
   g_wasProfitable[g_trackedCount]   = false;
   g_trackedCount++;
  }

//+------------------------------------------------------------------+
//| Remove tickets de posições que não existem mais (já fechadas)     |
//| para manter o array de rastreamento limpo                         |
//+------------------------------------------------------------------+
void CleanupTrackedPositions()
  {
   for(int i = g_trackedCount - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_trackedTickets[i]))
        {
         // posição fechada: remove do array (desloca os seguintes)
         for(int j = i; j < g_trackedCount - 1; j++)
           {
            g_trackedTickets[j] = g_trackedTickets[j + 1];
            g_wasProfitable[j]  = g_wasProfitable[j + 1];
           }
         g_trackedCount--;
        }
     }
  }

//+------------------------------------------------------------------+
//| Fecha a posição se ela já esteve em lucro em algum momento e o    |
//| preço retornou ao preço de entrada (breakeven antecipado),        |
//| recuperando o capital sem precisar esperar os InpMaxHoldDays      |
//| completos. NÃO fecha posições que nunca chegaram a ficar          |
//| positivas (evita fechar logo na abertura por flutuação de spread).|
//+------------------------------------------------------------------+
void CheckBreakeven()
  {
   if(!InpUseBreakeven)
      return;

   CleanupTrackedPositions();

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();

      TrackNewPosition(ticket);
      int idx = FindTrackedIndex(ticket);
      if(idx < 0)
         continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(bid > openPrice)
            g_wasProfitable[idx] = true; // marca que já esteve em lucro

         if(g_wasProfitable[idx] && bid <= openPrice)
           {
            Print("Posição #", ticket, " já esteve em lucro e retornou ao preço de entrada. Fechando no breakeven.");
            trade.PositionClose(ticket);
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(ask < openPrice)
            g_wasProfitable[idx] = true; // marca que já esteve em lucro

         if(g_wasProfitable[idx] && ask >= openPrice)
           {
            Print("Posição #", ticket, " já esteve em lucro e retornou ao preço de entrada. Fechando no breakeven.");
            trade.PositionClose(ticket);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Calcula o tamanho do lote baseado no % de risco e na distância   |
//| de referência (não é SL real, apenas dimensionamento)            |
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

   // Fecha antecipadamente no breakeven se o preço retornou ao open
   CheckBreakeven();

   // Gerencia trailing stop a cada tick (não precisa esperar nova barra)
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 0, 1, atrBuf) > 0)
      ManageTrailingStop(atrBuf[0]);

   // O sinal de entrada só é avaliado uma vez por barra nova
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
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
   if(!IsSessionOK())
      return;

   // Lê os indicadores na barra fechada anterior (índice 1)
   double emaBuf[], adxBuf[];
   ArraySetAsSeries(emaBuf, true);
   ArraySetAsSeries(adxBuf, true);

   if(CopyBuffer(hEMA, 0, 0, 3, emaBuf) < 3) return;
   if(CopyBuffer(hADX, 0, 0, 3, adxBuf) < 3) return; // linha principal do ADX
   if(CopyBuffer(hATR, 0, 0, 3, atrBuf) < 3) return;

   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 1);
   double emaPrev    = emaBuf[1];
   double adxPrev     = adxBuf[1];
   double atrPrev     = atrBuf[1];

   bool isUptrend   = closePrev > emaPrev;
   bool isDowntrend = closePrev < emaPrev;
   bool trendStrong = adxPrev >= InpADXMinLevel;

   double rangeHigh, rangeLow;
   if(!GetBreakoutRange(rangeHigh, rangeLow))
      return;

   bool buySignal  = isUptrend   && trendStrong && closePrev > rangeHigh;
   bool sellSignal = isDowntrend && trendStrong && closePrev < rangeLow;

   if(buySignal)
      OpenPosition(ORDER_TYPE_BUY, atrPrev);
   else if(sellSignal)
      OpenPosition(ORDER_TYPE_SELL, atrPrev);
  }

//+------------------------------------------------------------------+
//| Abre uma posição com TP calculado via ATR e lote via risco       |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType, double atrValue)
  {
   // ATENÇÃO: Esta versão do EA NÃO usa Stop Loss.
   // slDistance é usado apenas como referência para dimensionar o lote
   // e calcular o Take Profit — NÃO é enviado como SL real à corretora.
   // A posição só fecha via Take Profit, via breakeven antecipado
   // (CheckBreakeven) ou via prazo máximo (CheckMaxHoldTime).
   // O risco de perda NÃO tem limite definido enquanto a posição
   // estiver aberta.
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
      sent = trade.Buy(lots, _Symbol, price, 0, tp, "ScalperEA_XAUUSD Buy");
     }
   else
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp = NormalizeDouble(price - tpDistance, _Digits);
      sent = trade.Sell(lots, _Symbol, price, 0, tp, "ScalperEA_XAUUSD Sell");
     }

   if(sent)
      Print("Posição aberta SEM Stop Loss. Fechamento por TP, breakeven antecipado, ou em até ",
            InpMaxHoldDays, " dias (o que ocorrer primeiro).");
   else
      Print("Falha ao enviar ordem. Retcode: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
