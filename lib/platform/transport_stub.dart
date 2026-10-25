import '../core/models.dart';
import 'transport_base.dart';

List<PortInfo> enumeratePorts() => [];
Future<List<PortInfo>> enumeratePortsAsync() async => [];
Future<Transport> openTransport(ConnectionConfig config) async =>
    throw UnsupportedError('浏览器是界面与工具预览；真实串口及 TCP/UDP 请使用桌面应用');
