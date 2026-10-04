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
            borderRadius: BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
      ),
      home: const SettlementMainScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. 도메인 모델
// ---------------------------------------------------------------------------
class Participant {
  final String id;
  final String name;

  Participant({required this.id, required this.name});
}

class Expense {
  final String id;
  final String title;
  final int totalAmount;
  final String payerId;
  final List<String> involvedIds;

  Expense({
    required this.id,
    required this.title,
    required this.totalAmount,
    required this.payerId,
    required this.involvedIds,
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

// ---------------------------------------------------------------------------
// 2. 정산 계산 로직 (최소 송금 알고리즘)
// ---------------------------------------------------------------------------
class SettlementCalculator {
  static const int unit = 10; // 10원 단위 절사

  static List<TransferTransaction> calculateTransfers({
    required List<Participant> participants,
    required List<Expense> expenses,
  }) {
    if (participants.isEmpty || expenses.isEmpty) return [];

    final Map<String, int> netBalances = {for (var p in participants) p.id: 0};

    for (var expense in expenses) {
      if (expense.involvedIds.isEmpty) continue;

      netBalances[expense.payerId] =
          (netBalances[expense.payerId] ?? 0) + expense.totalAmount;

      int perPerson = (expense.totalAmount ~/ expense.involvedIds.length ~/ unit) * unit;
      int remainder = expense.totalAmount - (perPerson * expense.involvedIds.length);

      for (var i = 0; i < expense.involvedIds.length; i++) {
        var memberId = expense.involvedIds[i];
        int charge = perPerson + (i == 0 ? remainder : 0);
        netBalances[memberId] = (netBalances[memberId] ?? 0) - charge;
      }
    }

    List<MapEntry<String, int>> creditors = [];
    List<MapEntry<String, int>> debtors = [];

    netBalances.forEach((id, balance) {
      if (balance > 0) {
        creditors.add(MapEntry(id, balance));
      } else if (balance < 0) {
        debtors.add(MapEntry(id, -balance));
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
    Participant(id: '1', name: '김민수'),
    Participant(id: '2', name: '이영희'),
    Participant(id: '3', name: '박철수'),
  ];

  final List<Expense> _expenses = [
    Expense(
      id: 'e1',
      title: '1차 고깃집',
      totalAmount: 96000,
      payerId: '1',
      involvedIds: ['1', '2', '3'],
    ),
  ];

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

  void _addExpense(Expense expense) {
    setState(() {
      _expenses.add(expense);
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

  void _copyResultToClipboard(List<TransferTransaction> transfers, int totalSpent) {
    if (transfers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('정산할 내역이 없습니다.')),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('📢 [N빵 정산 내역서]');
    buffer.writeln('총 지출 금액: ${SettlementCalculator.formatCurrency(totalSpent)}원');
    buffer.writeln('참여자: ${_participants.map((p) => p.name).join(', ')}');
    buffer.writeln('\n🧾 [차수별 지출]');
    for (var exp in _expenses) {
      buffer.writeln(
          '• ${exp.title}: ${SettlementCalculator.formatCurrency(exp.totalAmount)}원 (결제자: ${_getParticipantName(exp.payerId)})');
    }
    buffer.writeln('\n💸 [최소 송금 안내]');
    for (var t in transfers) {
      buffer.writeln(
          '• ${_getParticipantName(t.senderId)} ➡️ ${_getParticipantName(t.receiverId)} : ${SettlementCalculator.formatCurrency(t.amount)}원');
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('정산 결과가 복사되었습니다. 카카오톡 등에 붙여넣기 하세요!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int totalSpent = _expenses.fold(0, (sum, e) => sum + e.totalAmount);
    final transfers = SettlementCalculator.calculateTransfers(
      participants: _participants,
      expenses: _expenses,
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
            _buildSettlementResultTab(transfers, totalSpent),
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
    return Scaffold(
      body: _expenses.isEmpty
          ? const Center(child: Text('지출 내역이 없습니다.\n아래 + 버튼을 눌러 추가하세요.', textAlign: TextAlign.center))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _expenses.length,
              itemBuilder: (context, index) {
                final exp = _expenses[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(exp.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            Text(
                              '${SettlementCalculator.formatCurrency(exp.totalAmount)}원',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF2563EB)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '결제자: ${_getParticipantName(exp.payerId)}',
                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '참여 (${exp.involvedIds.length}명): ${exp.involvedIds.map((id) => _getParticipantName(id)).join(', ')}',
                          style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                        ),
                        const Divider(height: 18),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                            label: const Text('삭제', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                            onPressed: () => _removeExpense(exp.id),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddExpenseModal,
        backgroundColor: const Color(0xFF2563EB),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('지출 등록', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _openAddExpenseModal() {
    if (_participants.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('정산을 위해 최소 2명 이상의 참가자가 필요합니다.')),
      );
      return;
    }

    final titleController = TextEditingController();
    final amountController = TextEditingController();
    String selectedPayerId = _participants.first.id;
    List<String> selectedInvolved = _participants.map((p) => p.id).toList();

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
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('지출 내역 등록', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 14),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(labelText: '내용 (예: 1차 삼겹살, 볼링장)'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: amountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '결제 총액 (원)', suffixText: '원'),
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
                    const SizedBox(height: 20),
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
                          _addExpense(Expense(
                            id: DateTime.now().millisecondsSinceEpoch.toString(),
                            title: titleController.text.trim(),
                            totalAmount: amount,
                            payerId: selectedPayerId,
                            involvedIds: selectedInvolved,
                          ));
                          Navigator.pop(ctx);
                        },
                        child: const Text('지출 저장'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSettlementResultTab(List<TransferTransaction> transfers, int totalSpent) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: const Color(0xFFEFF6FF),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('총 지출 금액', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1E3A8A))),
                  Text(
                    '${SettlementCalculator.formatCurrency(totalSpent)}원',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Color(0xFF1E40AF)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('최소 송금 가이드', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Expanded(
            child: transfers.isEmpty
                ? const Center(child: Text('정산할 내역이 없거나 모든 계산이 완료되었습니다.'))
                : ListView.builder(
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
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('카카오톡 공유 문구 복사', style: TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _copyResultToClipboard(transfers, totalSpent),
            ),
          ),
        ],
      ),
    );
  }
}
