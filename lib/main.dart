import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const DutchPayApp());
}

class DutchPayApp extends StatelessWidget {
  const DutchPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '스마트 N빵 정산기',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
      ),
      home: const SettlementMainScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. 도메인 모델 & 통화 정의
// ---------------------------------------------------------------------------
enum CurrencyType {
  jpy('JPY', '엔화 (¥)', '엔'),
  krw('KRW', '원화 (₩)', '원'),
  usd('USD', '달러 (\$)', '\$');

  final String code;
  final String label;
  final String unitSymbol;
  const CurrencyType(this.code, this.label, this.unitSymbol);
}

class Participant {
  final String id;
  final String name;

  Participant({required this.id, required this.name});
}

class Expense {
  final String id;
  final String title;
  final int totalAmount;
  final CurrencyType currency;
  final String payerId;
  final List<String> involvedIds;
  final DateTime dateTime;

  Expense({
    required this.id,
    required this.title,
    required this.totalAmount,
    this.currency = CurrencyType.jpy,
    required this.payerId,
    required this.involvedIds,
    required this.dateTime,
  });
}

class TransferTransaction {
  final String senderId;
  final String receiverId;
  final int amount;

  TransferTransaction({
    required this.senderId,
    required this.receiverId,
    required this.amount,
  });
}

class ParticipantSummary {
  final String participantId;
  final int totalPaid; // 결제한 금액
  final int totalUsed; // 사용(부담)한 금액
  final int netBalance; // 차액 (+: 받을 돈, -: 보낼 돈)

  ParticipantSummary({
    required this.participantId,
    required this.totalPaid,
    required this.totalUsed,
    required this.netBalance,
  });
}

// ---------------------------------------------------------------------------
// 2. 정산 계산 로직 (환율 환산 및 최소 송금)
// ---------------------------------------------------------------------------
class SettlementCalculator {
  static const int unit = 10; // 원화 10원 단위 절사
  static const List<String> _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  static int convertToKrw({
    required int amount,
    required CurrencyType currency,
    required double jpyRatePer100,
    required double usdRate,
  }) {
    switch (currency) {
      case CurrencyType.jpy:
        return (amount * (jpyRatePer100 / 100.0)).round();
      case CurrencyType.usd:
        return (amount * usdRate).round();
      case CurrencyType.krw:
        return amount;
    }
  }

  // 개인별 사용 금액 및 선결제 요약 계산
  static Map<String, ParticipantSummary> calculateParticipantSummaries({
    required List<Participant> participants,
    required List<Expense> expenses,
    required double jpyRatePer100,
    required double usdRate,
  }) {
    final Map<String, int> paidMap = {for (var p in participants) p.id: 0};
    final Map<String, int> usedMap = {for (var p in participants) p.id: 0};

    for (var expense in expenses) {
      if (expense.involvedIds.isEmpty) continue;

      int expenseAmountKrw = convertToKrw(
        amount: expense.totalAmount,
        currency: expense.currency,
        jpyRatePer100: jpyRatePer100,
        usdRate: usdRate,
      );

      // 결제자 총 결제액 누적
      paidMap[expense.payerId] = (paidMap[expense.payerId] ?? 0) + expenseAmountKrw;

      // 참석자별 균등 분할
      int perPerson = (expenseAmountKrw ~/ expense.involvedIds.length ~/ unit) * unit;
      int remainder = expenseAmountKrw - (perPerson * expense.involvedIds.length);

      for (var i = 0; i < expense.involvedIds.length; i++) {
        var memberId = expense.involvedIds[i];
        int charge = perPerson + (i == 0 ? remainder : 0);
        usedMap[memberId] = (usedMap[memberId] ?? 0) + charge;
      }
    }

    return {
      for (var p in participants)
        p.id: ParticipantSummary(
          participantId: p.id,
          totalPaid: paidMap[p.id] ?? 0,
          totalUsed: usedMap[p.id] ?? 0,
          netBalance: (paidMap[p.id] ?? 0) - (usedMap[p.id] ?? 0),
        )
    };
  }

  static List<TransferTransaction> calculateTransfers({
    required List<Participant> participants,
    required List<Expense> expenses,
    required double jpyRatePer100,
    required double usdRate,
  }) {
    if (participants.isEmpty || expenses.isEmpty) return [];

    final summaries = calculateParticipantSummaries(
      participants: participants,
      expenses: expenses,
      jpyRatePer100: jpyRatePer100,
      usdRate: usdRate,
    );

    List<MapEntry<String, int>> creditors = [];
    List<MapEntry<String, int>> debtors = [];

    summaries.forEach((id, summary) {
      if (summary.netBalance > 0) {
        creditors.add(MapEntry(id, summary.netBalance));
      } else if (summary.netBalance < 0) {
        debtors.add(MapEntry(id, -summary.netBalance));
      }
    });

    creditors.sort((a, b) => b.value.compareTo(a.value));
    debtors.sort((a, b) => b.value.compareTo(a.value));

    List<TransferTransaction> transactions = [];
    int cIdx = 0;
    int dIdx = 0;

    while (cIdx < creditors.length && dIdx < debtors.length) {
      var creditor = creditors[cIdx];
      var debtor = debtors[dIdx];

      int settleAmount = creditor.value < debtor.value ? creditor.value : debtor.value;

      transactions.add(TransferTransaction(
        senderId: debtor.key,
        receiverId: creditor.key,
        amount: settleAmount,
      ));

      creditors[cIdx] = MapEntry(creditor.key, creditor.value - settleAmount);
      debtors[dIdx] = MapEntry(debtor.key, debtor.value - settleAmount);

      if (creditors[cIdx].value == 0) cIdx++;
      if (debtors[dIdx].value == 0) dIdx++;
    }

    return transactions;
  }

  static String formatCurrency(int amount) {
    return amount.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  static String formatDateGroup(DateTime dt) {
    final w = _weekdays[dt.weekday - 1];
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}.$m.$d ($w)';
  }

  static String formatTimeOnly(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  static String formatDateTimeFull(DateTime dt) {
    return '${formatDateGroup(dt)} ${formatTimeOnly(dt)}';
  }
}

// ---------------------------------------------------------------------------
// 3. 메인 화면
// ---------------------------------------------------------------------------
class SettlementMainScreen extends StatefulWidget {
  const SettlementMainScreen({super.key});

  @override
  State<SettlementMainScreen> createState() => _SettlementMainScreenState();
}

class _SettlementMainScreenState extends State<SettlementMainScreen> {
  final List<Participant> _participants = [
    Participant(id: '1', name: '기명'),
    Participant(id: '2', name: '쩝'),
    Participant(id: '3', name: '인발'),
  ];

  final List<Expense> _expenses = [
    Expense(
      id: 'e1',
      title: '1차 라멘',
      totalAmount: 4500,
      currency: CurrencyType.jpy,
      payerId: '1',
      involvedIds: ['1', '2', '3'],
      dateTime: DateTime.now(),
    ),
  ];

  double _jpyRate = 920.0;
  final double _usdRate = 1380.0;
  late final TextEditingController _jpyRateController;

  @override
  void initState() {
    super.initState();
    _jpyRateController = TextEditingController(text: _jpyRate.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _jpyRateController.dispose();
    super.dispose();
  }

  void _addParticipant(String name) {
    if (name.trim().isEmpty) return;
    setState(() {
      _participants.add(Participant(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name.trim(),
      ));
    });
  }

  void _removeParticipant(String id) {
    setState(() {
      _participants.removeWhere((p) => p.id == id);
      _expenses.removeWhere((e) => e.payerId == id);
      for (var e in _expenses) {
        e.involvedIds.remove(id);
      }
    });
  }

  void _saveExpense(Expense expense, {bool isEdit = false}) {
    setState(() {
      if (isEdit) {
        final index = _expenses.indexWhere((e) => e.id == expense.id);
        if (index != -1) {
          _expenses[index] = expense;
        }
      } else {
        _expenses.add(expense);
      }
    });
  }

  void _removeExpense(String id) {
    setState(() {
      _expenses.removeWhere((e) => e.id == id);
    });
  }

  String _getParticipantName(String id) {
    return _participants
        .firstWhere((p) => p.id == id, orElse: () => Participant(id: '', name: '알 수 없음'))
        .name;
  }

  void _copyResultToClipboard(
    List<TransferTransaction> transfers,
    int totalSpentKrw,
    Map<String, ParticipantSummary> summaries,
  ) {
    if (transfers.isEmpty && summaries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('정산할 내역이 없습니다.')),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('📢 [N빵 정산 내역서 (원화 환산)]');
    buffer.writeln('적용 환율: 100엔당 ${_jpyRate.toStringAsFixed(0)}원');
    buffer.writeln('총 지출액: ${SettlementCalculator.formatCurrency(totalSpentKrw)}원');

    buffer.writeln('\n👤 [개인별 사용(부담) 금액]');
    for (var p in _participants) {
      final s = summaries[p.id];
      if (s != null) {
        buffer.writeln(
            '• ${p.name}: 사용 ${SettlementCalculator.formatCurrency(s.totalUsed)}원 (결제 ${SettlementCalculator.formatCurrency(s.totalPaid)}원)');
      }
    }

    buffer.writeln('\n🧾 [지출 상세 내역]');
    for (var exp in _expenses) {
      final dateStr = SettlementCalculator.formatDateTimeFull(exp.dateTime);
      final krwVal = SettlementCalculator.convertToKrw(
        amount: exp.totalAmount,
        currency: exp.currency,
        jpyRatePer100: _jpyRate,
        usdRate: _usdRate,
      );
      buffer.writeln(
          '• ${exp.title} ($dateStr): ${SettlementCalculator.formatCurrency(exp.totalAmount)}${exp.currency.unitSymbol} (약 ${SettlementCalculator.formatCurrency(krwVal)}원) [결제: ${_getParticipantName(exp.payerId)}]');
    }

    buffer.writeln('\n💸 [한국 원화 송금 가이드]');
    if (transfers.isEmpty) {
      buffer.writeln('• 모든 정산이 완료되었습니다.');
    } else {
      for (var t in transfers) {
        buffer.writeln(
            '• ${_getParticipantName(t.senderId)} ➡️ ${_getParticipantName(t.receiverId)} : ${SettlementCalculator.formatCurrency(t.amount)}원');
      }
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('개인별 사용금액이 포함된 결과가 복사되었습니다!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int totalSpentKrw = _expenses.fold(0, (sum, e) {
      return sum +
          SettlementCalculator.convertToKrw(
            amount: e.totalAmount,
            currency: e.currency,
            jpyRatePer100: _jpyRate,
            usdRate: _usdRate,
          );
    });

    final summaries = SettlementCalculator.calculateParticipantSummaries(
      participants: _participants,
      expenses: _expenses,
      jpyRatePer100: _jpyRate,
      usdRate: _usdRate,
    );

    final transfers = SettlementCalculator.calculateTransfers(
      participants: _participants,
      expenses: _expenses,
      jpyRatePer100: _jpyRate,
      usdRate: _usdRate,
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('N빵 스마트 정산기', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF1E293B),
          elevation: 0.5,
          bottom: const TabBar(
            labelColor: Color(0xFF2563EB),
            indicatorColor: Color(0xFF2563EB),
            tabs: [
              Tab(text: '1. 참가자'),
              Tab(text: '2. 지출 등록'),
              Tab(text: '3. 정산 결과'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildParticipantsTab(),
            _buildExpensesTab(),
            _buildSettlementResultTab(transfers, totalSpentKrw, summaries),
          ],
        ),
      ),
    );
  }

  Widget _buildParticipantsTab() {
    final textController = TextEditingController();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textController,
                  decoration: const InputDecoration(
                    hintText: '이름 입력 (예: 홍길동)',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                      borderSide: BorderSide(color: Color(0xFFCBD5E1)),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  _addParticipant(textController.text);
                  textController.clear();
                },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                ),
                child: const Text('추가'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '참가 인원 (${_participants.length}명)',
            style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _participants.isEmpty
                ? const Center(child: Text('정산에 참여할 인원을 추가해 주세요.'))
                : ListView.builder(
                    itemCount: _participants.length,
                    itemBuilder: (context, index) {
                      final p = _participants[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFFEFF6FF),
                            child: Text(
                              p.name.isNotEmpty ? p.name[0] : '?',
                              style: const TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold),
                            ),
                          ),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8)),
                            onPressed: () => _removeParticipant(p.id),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpensesTab() {
    if (_expenses.isEmpty) {
      return Scaffold(
        body: const Center(
          child: Text('지출 내역이 없습니다.\n아래 + 버튼을 눌러 추가하세요.', textAlign: TextAlign.center),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openExpenseFormModal(),
          backgroundColor: const Color(0xFF2563EB),
          icon: const Icon(Icons.add, color: Colors.white),
          label: const Text('지출 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      );
    }

    final sortedExpenses = List<Expense>.from(_expenses)
      ..sort((a, b) => b.dateTime.compareTo(a.dateTime));

    final Map<String, List<Expense>> grouped = {};
    for (var exp in sortedExpenses) {
      final dateKey = SettlementCalculator.formatDateGroup(exp.dateTime);
      grouped.putIfAbsent(dateKey, () => []).add(exp);
    }

    final dateKeys = grouped.keys.toList();

    return Scaffold(
      body: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount: dateKeys.length,
        itemBuilder: (context, index) {
          final dateKey = dateKeys[index];
          final dayExpenses = grouped[dateKey]!;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 14, color: Color(0xFF2563EB)),
                    const SizedBox(width: 6),
                    Text(
                      dateKey,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E293B)),
                    ),
                  ],
                ),
              ),
              ...dayExpenses.map((exp) {
                final krwVal = SettlementCalculator.convertToKrw(
                  amount: exp.totalAmount,
                  currency: exp.currency,
                  jpyRatePer100: _jpyRate,
                  usdRate: _usdRate,
                );

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    SettlementCalculator.formatTimeOnly(exp.dateTime),
                                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      exp.title,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${SettlementCalculator.formatCurrency(exp.totalAmount)}${exp.currency.unitSymbol}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF2563EB)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      '결제: ${_getParticipantName(exp.payerId)} · 참여(${exp.involvedIds.length}명): ${exp.involvedIds.map((id) => _getParticipantName(id)).join(', ')}',
                                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (exp.currency != CurrencyType.krw)
                                    Text(
                                      '≈ ${SettlementCalculator.formatCurrency(krwVal)}원',
                                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF64748B)),
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          padding: EdgeInsets.zero,
                          tooltip: '수정',
                          onPressed: () => _openExpenseFormModal(expenseToEdit: exp),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          padding: EdgeInsets.zero,
                          tooltip: '삭제',
                          onPressed: () => _removeExpense(exp.id),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openExpenseFormModal(),
        backgroundColor: const Color(0xFF2563EB),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('지출 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  // 지출 등록 및 수정 모달 (통화와 결제총액 라인 완벽 일치)
  void _openExpenseFormModal({Expense? expenseToEdit}) {
    if (_participants.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('정산을 위해 최소 2명 이상의 참가자가 필요합니다.')),
      );
      return;
    }

    final bool isEdit = expenseToEdit != null;
    final titleController = TextEditingController(text: isEdit ? expenseToEdit.title : '');
    final amountController = TextEditingController(text: isEdit ? expenseToEdit.totalAmount.toString() : '');
    CurrencyType selectedCurrency = isEdit ? expenseToEdit.currency : CurrencyType.jpy;
    String selectedPayerId = isEdit ? expenseToEdit.payerId : _participants.first.id;

    if (!_participants.any((p) => p.id == selectedPayerId)) {
      selectedPayerId = _participants.first.id;
    }

    List<String> selectedInvolved = isEdit
        ? List.from(expenseToEdit.involvedIds)
        : _participants.map((p) => p.id).toList();

    DateTime selectedDateTime = isEdit ? expenseToEdit.dateTime : DateTime.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final bottomInset = MediaQuery.of(context).viewInsets.bottom;
            final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom: bottomInset + bottomPadding + 36,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEdit ? '지출 내역 수정' : '지출 내역 등록',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: titleController,
                        decoration: const InputDecoration(
                          labelText: '내용 (예: 1차 라멘, 편의점)',
                          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 통화와 금액 입력란 높이 및 기준선 정렬 완료
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 125,
                            child: DropdownButtonFormField<CurrencyType>(
                              value: selectedCurrency,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '통화',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.all(Radius.circular(8)),
                                ),
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                              ),
                              items: CurrencyType.values.map((c) {
                                return DropdownMenuItem(
                                  value: c,
                                  child: Text(c.label, style: const TextStyle(fontSize: 13)),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setModalState(() => selectedCurrency = val);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: amountController,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: '결제 총액',
                                suffixText: selectedCurrency.unitSymbol,
                                border: const OutlineInputBorder(
                                  borderRadius: BorderRadius.all(Radius.circular(8)),
                                ),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      const Text('지출 일시', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final pickedDate = await showDatePicker(
                            context: context,
                            initialDate: selectedDateTime,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2035),
                          );
                          if (pickedDate == null || !ctx.mounted) return;

                          final pickedTime = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(selectedDateTime),
                          );
                          if (pickedTime == null) return;

                          setModalState(() {
                            selectedDateTime = DateTime(
                              pickedDate.year,
                              pickedDate.month,
                              pickedDate.day,
                              pickedTime.hour,
                              pickedTime.minute,
                            );
                          });
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFCBD5E1)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.calendar_month_outlined, size: 18, color: Color(0xFF2563EB)),
                                  const SizedBox(width: 8),
                                  Text(
                                    SettlementCalculator.formatDateTimeFull(selectedDateTime),
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF1E293B)),
                                  ),
                                ],
                              ),
                              const Text(
                                '변경',
                                style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text('누가 결제했나요?', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                      DropdownButton<String>(
                        value: selectedPayerId,
                        isExpanded: true,
                        items: _participants.map((p) {
                          return DropdownMenuItem(value: p.id, child: Text(p.name));
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) setModalState(() => selectedPayerId = val);
                        },
                      ),
                      const SizedBox(height: 14),

                      const Text('누가 함께했나요?', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: _participants.map((p) {
                          final isSelected = selectedInvolved.contains(p.id);
                          return FilterChip(
                            label: Text(p.name),
                            selected: isSelected,
                            onSelected: (selected) {
                              setModalState(() {
                                if (selected) {
                                  selectedInvolved.add(p.id);
                                } else {
                                  selectedInvolved.remove(p.id);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),

                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {
                            final int? amount = int.tryParse(amountController.text.replaceAll(',', ''));
                            if (titleController.text.trim().isEmpty || amount == null || amount <= 0 || selectedInvolved.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('입력 항목을 모두 올바르게 채워주세요.')),
                              );
                              return;
                            }

                            final updatedExpense = Expense(
                              id: isEdit ? expenseToEdit.id : DateTime.now().millisecondsSinceEpoch.toString(),
                              title: titleController.text.trim(),
                              totalAmount: amount,
                              currency: selectedCurrency,
                              payerId: selectedPayerId,
                              involvedIds: selectedInvolved,
                              dateTime: selectedDateTime,
                            );

                            _saveExpense(updatedExpense, isEdit: isEdit);
                            Navigator.pop(ctx);
                          },
                          child: Text(isEdit ? '수정 완료' : '지출 저장'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // 정산 결과 화면: 개인별 사용 금액 및 환율 계산 반영
  Widget _buildSettlementResultTab(
    List<TransferTransaction> transfers,
    int totalSpentKrw,
    Map<String, ParticipantSummary> summaries,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 환율 설정 카드
          Card(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.currency_exchange, color: Color(0xFF2563EB), size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '엔화 환율 (100엔당)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF334155)),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    height: 38,
                    child: TextField(
                      controller: _jpyRateController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.end,
                      decoration: const InputDecoration(
                        suffixText: '원',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final parsed = double.tryParse(val);
                        if (parsed != null && parsed > 0) {
                          setState(() {
                            _jpyRate = parsed;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 총 지출 요약 카드
          Card(
            color: const Color(0xFFEFF6FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('총 지출액 (원화 환산)', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1E3A8A))),
                  Text(
                    '${SettlementCalculator.formatCurrency(totalSpentKrw)}원',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Color(0xFF1E40AF)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 개인별 정산 요약 카드 목록
          const Text('개인별 사용(부담) 금액', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ..._participants.map((p) {
            final s = summaries[p.id] ?? ParticipantSummary(participantId: p.id, totalPaid: 0, totalUsed: 0, netBalance: 0);
            final bool isCreditor = s.netBalance > 0;
            final bool isDebtor = s.netBalance < 0;

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: const Color(0xFFEFF6FF),
                      child: Text(
                        p.name.isNotEmpty ? p.name[0] : '?',
                        style: const TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 2),
                          Text(
                            '선결제액: ${SettlementCalculator.formatCurrency(s.totalPaid)}원',
                            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '사용: ${SettlementCalculator.formatCurrency(s.totalUsed)}원',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isCreditor
                              ? '+${SettlementCalculator.formatCurrency(s.netBalance)}원 수령'
                              : isDebtor
                                  ? '-${SettlementCalculator.formatCurrency(-s.netBalance)}원 송금'
                                  : '정산 완료',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: isCreditor
                                ? const Color(0xFF16A34A)
                                : isDebtor
                                    ? Colors.redAccent
                                    : const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),

          // 최소 송금 가이드
          const Text('한국 원화 송금 가이드', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),

          transfers.isEmpty
              ? const Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('정산할 내역이 없거나 모든 계산이 완료되었습니다.')),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: transfers.length,
                  itemBuilder: (context, index) {
                    final t = transfers[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF2563EB)),
                        title: Row(
                          children: [
                            Text(_getParticipantName(t.senderId), style: const TextStyle(fontWeight: FontWeight.bold)),
                            const Text(' ➡️ ', style: TextStyle(fontSize: 12)),
                            Text(_getParticipantName(t.receiverId), style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        trailing: Text(
                          '${SettlementCalculator.formatCurrency(t.amount)}원',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF0F172A)),
                        ),
                      ),
                    );
                  },
                ),
          const SizedBox(height: 14),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('카카오톡 공유 문구 복사 (원화 기준)', style: TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _copyResultToClipboard(transfers, totalSpentKrw, summaries),
            ),
          ),
        ],
      ),
    );
  }
}
