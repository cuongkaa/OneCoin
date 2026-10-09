

import '../model/TransactionModel.dart';

class TabTransaction{

  late String name;
  late DateTime from;
  late DateTime to;
  bool isFuture = false;
  bool isAll = false;
  List<TransactionModel>  transactions = [];

  TabTransaction(this.name, this.from, this.to);
}