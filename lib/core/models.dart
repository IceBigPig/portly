import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'bytes.dart';
import 'command.dart';

export 'command.dart';

String newId() => const Uuid().v4();

enum ConnectionKind { serial, tcpClient, tcpServer, udp }

extension KindName on ConnectionKind {
  String get label => ['串口', 'TCP 客户端', 'TCP 服务端', 'UDP'][index];
}

class ConnectionConfig {
  String id, name, port, host, bindAddress, targetHost, parity, flowControl;
  ConnectionKind kind;
  int baud, dataBits, stopBits, networkPort, targetPort, timeoutMs;
  int reconnectIntervalMs, reconnectMaxAttempts;
  bool broadcast, autoReconnect;
  bool? dtr, rts;
  ConnectionConfig({
    String? id,
    this.name = '串口 01',
    this.kind = ConnectionKind.serial,
    this.port = '',
    this.host = '',
    this.bindAddress = '0.0.0.0',
    this.targetHost = '',
    this.parity = 'None',
    this.flowControl = '无',
    this.baud = 115200,
    this.dataBits = 8,
    this.stopBits = 1,
    this.networkPort = 9000,
    this.targetPort = 9001,
    this.timeoutMs = 5000,
    this.broadcast = false,
    this.autoReconnect = false,
    this.reconnectIntervalMs = 2000,
    this.reconnectMaxAttempts = 10,
    this.dtr,
    this.rts,
  }) : id = id ?? newId();
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'port': port,
    'host': host,
    'bindAddress': bindAddress,
    'targetHost': targetHost,
    'parity': parity,
    'flowControl': flowControl,
    'baud': baud,
    'dataBits': dataBits,
    'stopBits': stopBits,
    'networkPort': networkPort,
    'targetPort': targetPort,
    'timeoutMs': timeoutMs,
    'broadcast': broadcast,
    'autoReconnect': autoReconnect,
    'reconnectIntervalMs': reconnectIntervalMs,
    'reconnectMaxAttempts': reconnectMaxAttempts,
    'dtr': dtr,
    'rts': rts,
  };
  factory ConnectionConfig.fromJson(Map<String, dynamic> j) => ConnectionConfig(
    id: j['id'],
    name: j['name'] ?? '新会话',
    kind: ConnectionKind.values.byName(j['kind'] ?? 'serial'),
    port: j['port'] ?? '',
    host: j['host'] ?? '',
    bindAddress: j['bindAddress'] ?? '0.0.0.0',
    targetHost: j['targetHost'] ?? '',
    parity: j['parity'] ?? 'None',
    flowControl: j['flowControl'] ?? '无',
    baud: j['baud'] ?? 115200,
    dataBits: j['dataBits'] ?? 8,
    stopBits: j['stopBits'] ?? 1,
    networkPort: j['networkPort'] ?? 9000,
    targetPort: j['targetPort'] ?? 9001,
    timeoutMs: j['timeoutMs'] ?? 5000,
    broadcast: j['broadcast'] ?? false,
    autoReconnect: j['autoReconnect'] ?? false,
    reconnectIntervalMs: j['reconnectIntervalMs'] ?? 2000,
    reconnectMaxAttempts: j['reconnectMaxAttempts'] ?? 10,
    dtr: j['dtr'],
    rts: j['rts'],
  );
  ConnectionConfig copy() => ConnectionConfig.fromJson(toJson());
  String get summary => switch (kind) {
    ConnectionKind.serial =>
      '${port.isEmpty ? '未选择端口' : port} · $baud · $dataBits${parity == 'None' ? 'N' : parity[0]}$stopBits',
    ConnectionKind.tcpClient => '${host.isEmpty ? '未设置地址' : host}:$networkPort',
    _ => '$bindAddress:$networkPort',
  };
}

class Draft {
  String body, encoding, suffix;
  bool text, crc;
  Draft({
    this.body = '',
    this.encoding = 'UTF-8',
    this.suffix = '',
    this.text = false,
    this.crc = false,
  });
  Uint8List build() => buildBytes(
    body: body,
    text: text,
    encoding: encoding,
    suffix: suffix,
    crc: crc,
  );
  Map<String, dynamic> toJson() => {
    'body': body,
    'encoding': encoding,
    'suffix': suffix,
    'text': text,
    'crc': crc,
  };
  factory Draft.fromJson(Map<String, dynamic> j) => Draft(
    body: j['body'] ?? '',
    encoding: j['encoding'] ?? 'UTF-8',
    suffix: j['suffix'] ?? '',
    text: j['text'] ?? false,
    crc: j['crc'] ?? false,
  );
  Draft copy() => Draft.fromJson(toJson());
}

class SavedCommand {
  String id, groupId, name, note;
  Draft draft;
  int revision, timeoutMs, stepDelayMs;
  List<CommandParameter> parameters;
  ResponseRule? responseRule;
  List<String> tags;
  int sortOrder;
  String? createdAt, updatedAt;
  SavedCommand({
    String? id,
    this.groupId = 'default',
    required this.name,
    required this.draft,
    this.note = '',
    this.revision = 1,
    this.timeoutMs = 1000,
    this.stepDelayMs = 1000,
    List<CommandParameter>? parameters,
    this.responseRule,
    List<String>? tags,
    this.sortOrder = 0,
    this.createdAt,
    this.updatedAt,
  }) : id = id ?? newId(),
       parameters = parameters ?? [],
       tags = tags ?? [];
  Draft buildDraft([Map<String, String> values = const {}]) => draft.copy()
    ..body = substituteParameters(
      draft.body,
      parameters,
      values,
      text: draft.text,
      encoding: draft.encoding,
    );
  Uint8List buildBytes([Map<String, String> values = const {}]) =>
      buildDraft(values).build();
  void validate() {
    if (id.isEmpty ||
        groupId.isEmpty ||
        name.trim().isEmpty ||
        name.length > 80) {
      throw const FormatException('命令 ID、分组或名称无效');
    }
    if (revision < 1 ||
        timeoutMs < 10 ||
        timeoutMs > 600000 ||
        stepDelayMs < 10 ||
        stepDelayMs > 86400000) {
      throw const FormatException('命令版本、超时或步骤延时超出范围');
    }
    if (tags.length > 64 ||
        tags.any((t) => t.trim().isEmpty || t.length > 80)) {
      throw const FormatException('命令标签无效');
    }
    if (!['UTF-8', 'ASCII', 'UTF-16LE', 'UTF-16BE'].contains(draft.encoding)) {
      throw const FormatException('不支持的文本编码');
    }
    final bytes = buildBytes();
    responseRule?.validate();
    if (responseRule != null && responseRule!.kind != 'none') {
      ResponseMatcher(responseRule!, bytes);
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'groupId': groupId,
    'name': name,
    'format': draft.text ? 'text' : 'hex',
    if (draft.text) 'bodyText': draft.body else 'bodyHex': draft.body,
    'encoding': draft.encoding,
    'suffixHex': draft.suffix,
    'checksumMode': draft.crc ? 'modbus_crc16' : 'raw',
    'revision': revision,
    'timeoutMs': timeoutMs,
    'stepDelayMs': stepDelayMs,
    'note': note,
    'parameters': parameters.map((p) => p.toJson()).toList(),
    if (responseRule != null) 'responseRule': responseRule!.toJson(),
    'tags': tags,
    'sortOrder': sortOrder,
    if (createdAt != null) 'createdAt': createdAt,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };
  factory SavedCommand.fromJson(Map<String, dynamic> j) {
    const supported = {
      'id',
      'groupId',
      'name',
      'format',
      'bodyHex',
      'bodyText',
      'encoding',
      'suffixHex',
      'checksumMode',
      'revision',
      'timeoutMs',
      'stepDelayMs',
      'note',
      'parameters',
      'responseRule',
      'tags',
      'sortOrder',
      'createdAt',
      'updatedAt',
    };
    for (final key in j.keys) {
      if (!supported.contains(key)) throw FormatException('命令包含未支持的字段 $key');
    }
    if (j['id'] is! String ||
        j['name'] is! String ||
        (j['name'] as String).trim().isEmpty ||
        (j['name'] as String).length > 80) {
      throw const FormatException('命令 ID 或名称无效');
    }
    if (!['hex', 'text'].contains(j['format']) ||
        !['raw', 'modbus_crc16'].contains(j['checksumMode'])) {
      throw const FormatException('命令格式或校验策略无效');
    }
    final text = j['format'] == 'text';
    if (j[text ? 'bodyText' : 'bodyHex'] is! String ||
        j.containsKey(text ? 'bodyHex' : 'bodyText')) {
      throw const FormatException('命令正文须与格式一致且只保留一份');
    }
    for (final field in [
      'groupId',
      'encoding',
      'suffixHex',
      'note',
      'createdAt',
      'updatedAt',
    ]) {
      if (j[field] != null && j[field] is! String) {
        throw FormatException('命令 $field 类型无效');
      }
    }
    for (final field in ['revision', 'timeoutMs', 'stepDelayMs', 'sortOrder']) {
      if (j[field] != null && j[field] is! int) {
        throw FormatException('命令 $field 类型无效');
      }
    }
    if ((j['parameters'] != null && j['parameters'] is! List) ||
        (j['tags'] != null &&
            (j['tags'] is! List ||
                (j['tags'] as List).any((t) => t is! String))) ||
        (j['responseRule'] != null && j['responseRule'] is! Map)) {
      throw const FormatException('命令参数、标签或响应规则类型无效');
    }
    final draft = Draft(
      body: j[text ? 'bodyText' : 'bodyHex'] as String,
      text: text,
      encoding: j['encoding'] ?? 'UTF-8',
      suffix: j['suffixHex'] ?? '',
      crc: j['checksumMode'] == 'modbus_crc16',
    );
    if (!['UTF-8', 'ASCII', 'UTF-16LE', 'UTF-16BE'].contains(draft.encoding)) {
      throw const FormatException('不支持的文本编码');
    }
    final timeout = j['timeoutMs'] as int? ?? 1000,
        delay = j['stepDelayMs'] as int? ?? 1000;
    if (timeout < 10 || timeout > 600000 || delay < 10 || delay > 86400000) {
      throw const FormatException('命令超时或步骤延时超出范围');
    }
    final command = SavedCommand(
      id: j['id'],
      groupId: j['groupId'] ?? 'default',
      name: j['name'],
      draft: draft,
      revision: j['revision'] ?? 1,
      note: j['note'] ?? '',
      timeoutMs: timeout,
      stepDelayMs: delay,
      parameters: (j['parameters'] as List? ?? []).map((p) {
        if (p is! Map) throw const FormatException('参数定义必须为对象');
        return CommandParameter.fromJson(Map<String, dynamic>.from(p));
      }).toList(),
      responseRule:
          j['responseRule'] == null || (j['responseRule'] as Map).isEmpty
          ? null
          : ResponseRule.fromJson(Map<String, dynamic>.from(j['responseRule'])),
      tags: List<String>.from(j['tags'] ?? []),
      sortOrder: j['sortOrder'] ?? 0,
      createdAt: j['createdAt'],
      updatedAt: j['updatedAt'],
    );
    command.validate();
    return command;
  }
}

class LogEntry {
  int sequence = 0;
  final String id, direction, endpoint, message;
  final DateTime time;
  final Uint8List bytes;
  LogEntry(
    this.direction,
    List<int> data, {
    this.endpoint = '',
    this.message = '',
    String? id,
    DateTime? time,
  }) : id = id ?? newId(),
       time = time ?? DateTime.now(),
       bytes = Uint8List.fromList(data);
  String get timestamp =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time.toUtc().toIso8601String(),
    'utcOffsetMinutes': time.timeZoneOffset.inMinutes,
    'direction': direction,
    'sequence': sequence,
    'endpoint': endpoint,
    'hex': hex(bytes),
    'message': message,
  };
}
