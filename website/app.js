import {
  parseHex,
  hex,
  crc16,
  modbusCommand,
  convertBase,
  reverseBytes,
  nmeaChecksum,
} from "./tool-core.mjs";

const en = {
  skip: "Skip to main content",
  navProduct: "Product",
  navWorkflow: "Workflow",
  navDocs: "Docs",
  navReleases: "Releases",
  download: "Download",
  getApp: "Get desktop app",
  heroLabel: "THE OPEN-SOURCE DEBUGGING WORKBENCH",
  heroTitle: "Make sense<br>of every <span>byte.</span>",
  heroDescription:
    "Serial, TCP and UDP. One focused workspace. Connect devices, reuse commands and inspect the data that matters.",
  getPortly: "Get Portly",
  exploreWorkflow: "Explore the workflow",
  platforms: "macOS & Windows",
  appSubtitle: "Debugging workbench",
  interactiveDemo: "INTERACTIVE DEMO",
  debug: "Workspace",
  waveform: "Waveform",
  toolbox: "Toolbox",
  connection: "Connection",
  connectionType: "Protocol",
  serial: "Serial",
  tcpClient: "TCP Client",
  tcpServer: "TCP Server",
  device: "Device",
  baud: "Baud rate",
  dataBits: "Data bits",
  parity: "Parity",
  stopBits: "Stop bits",
  flowControl: "Flow control",
  demoConnected: "Demo connected",
  connectionReady: "Connection ready",
  timestampScroll: "☑ Timestamp　☑ Autoscroll",
  dataLog: "Data log",
  text: "Text",
  time: "Time",
  direction: "Dir",
  data: "Data",
  singleSend: "Single send",
  savedCommands: "Commands · 2",
  hexInput: "HEX INPUT",
  rawSend: "Raw bytes",
  loop: "□ Loop",
  send: "Send",
  demoStatus: "Demo mode · No device connection",
  previewCaption: "Try another protocol, view text, or send a demo packet.",
  workflowLabel: "01 / THE WORKFLOW",
  workflowTitle: "Less setup.<br>More understanding.",
  connect: "Connect",
  connectDescription: "Serial or network.",
  sendDescription: "One command or a sequence.",
  inspect: "Inspect",
  inspectDescription: "Bytes, responses and waveforms.",
  reuse: "Reuse",
  reuseDescription: "Keep your commands organized.",
  commandsLabel: "02 / COMMANDS WITH CONTEXT",
  commandsTitle: "Write once.<br>Run with intent.",
  commandsDescription:
    "Group your commands, add parameters and define the response you expect.",
  parameters: "Parameters",
  responseMatching: "Response matching",
  executionHistory: "Execution history",
  commandLink: "Explore command workflows",
  readRegisters: "Read holding registers",
  livePreview: "LIVE PREVIEW",
  deviceAddress: "Device address",
  startAddress: "Start address",
  quantity: "Quantity",
  commandHex: "COMMAND (HEX)",
  crcAfterParameters: "CRC appended after parameters",
  loadCommand: "Load into the demo above ↑",
  responseExample: "Example: 01 03 04 …",
  writeRegister: "Write single register",
  waiting: "No response yet",
  inspectLabel: "03 / LOOK CLOSER",
  inspectTitle: "See the signal.<br>Find the detail.",
  inspectDetail:
    "Follow up to eight channels, inspect individual bytes and search recorded logs. Make every change traceable.",
  inspectLink: "Inside the workspace",
  sampleData: "SAMPLE DATA",
  labLabel: "04 / THE BYTE LAB",
  labTitle: "A small lab<br>for every byte.",
  labDescription: "Check a frame. Convert a value. Get back to debugging.",
  labNote: "Try the tools with your own data.",
  baseConversion: "Base conversion",
  byteOrder: "Byte order",
  nmeaChecksum: "NMEA checksum",
  crcDescription: "Compute the Modbus RTU CRC16 for your data frame.",
  clear: "Clear",
  crcResult: "CRC16 RESULT",
  wireBytes: "Wire bytes (low byte first)",
  copyResult: "Copy result",
  downloadLabel: "05 / DOWNLOAD",
  downloadTitle: "Your next session<br>starts here.",
  latest: "Latest release",
  downloadDmg: "Download DMG",
  chooseBuild: "Choose build",
  installer: "Installer .exe",
  portable: "Portable .zip",
  linuxStatus: "No release package yet",
  viewSource: "View source",
  allReleases: "All releases & installation notes",
  installNote:
    "macOS builds are not notarized; Windows packages are unsigned. See the release page for installation instructions and SHA-256 checksums.",
  faqTitle: "A few things to know.",
  faqConnections: "Which connections are supported?",
  faqConnectionsAnswer:
    "Serial, TCP client, TCP server and UDP. Serial supports custom baud rates, automatic reconnection and DTR / RTS control. Network connections support configurable listening addresses and targets.",
  faqPlatforms: "Which platforms can I download?",
  faqPlatformsAnswer:
    "macOS DMG and ZIP packages are available for Apple Silicon, requiring macOS 13 or later. Windows has x64 and ARM64 installers and portable ZIP packages. Linux source is included, with no release package yet.",
  faqOpenSource: "Is Portly open source?",
  faqOpenSourceAnswer:
    "Yes. Portly source is licensed under Apache-2.0. Read the code, report issues and contribute on GitHub. Third-party licenses and corresponding LGPL source are included with releases.",
  faqBrowser: "Can I connect a serial device in the browser?",
  faqBrowserAnswer:
    "This website presents the product and interactive examples. The demos do not connect to real devices. Download the desktop app for serial and network connections, logs and waveforms.",
  openSourceLabel: "06 / OPEN SOURCE",
  openSourceTitle: "Built in the open.",
  openSourceDescription:
    "Source code, documentation and feedback.\nHelp shape a better debugging tool.",
  documentation: "Documentation",
  reportIssue: "Report an issue",
  workbenchPreview: "Portly workspace · Interactive demo",
};
const zh = Object.fromEntries(
  [...document.querySelectorAll("[data-i18n]")].map((element) => [
    element.dataset.i18n,
    element.textContent.trim().replace(/\s+/g, " "),
  ]),
);
for (const element of document.querySelectorAll("[data-i18n-html]"))
  zh[element.dataset.i18nHtml] = element.innerHTML;
const messages = {
  zh: {
    hex: "请输入完整的十六进制字节，例如 01 03 00 00 00 02。",
    length: "一次最多处理 4096 字节。",
    number: "请输入 0～2⁶⁴−1 的整数；十六进制以 0x 开头，二进制以 0b 开头。",
    endian: "请输入 2、4 或 8 个十六进制字节。",
    nmea: "请输入 ASCII 格式的 NMEA 语句正文。",
    parameters:
      "参数无效：地址为 HEX，数量须为 0001～007D，且不能超出寄存器地址范围。",
    sent: "演示报文已加入日志，未发送至真实设备。",
    loaded: "命令已载入演示台。",
    copied: "已复制到剪贴板。",
    copyFailed: "无法访问剪贴板，请直接选中结果复制。",
    empty: "请输入数据。",
    ip: "目标地址",
    port: "端口",
    bind: "监听地址",
    menu: "打开导航",
    close: "关闭预览",
    expand: "放大工作台预览",
    chart: "两通道波形示例",
  },
  en: {
    hex: "Enter complete HEX bytes, such as 01 03 00 00 00 02.",
    length: "Up to 4096 bytes at a time.",
    number:
      "Enter an integer from 0 to 2⁶⁴−1. Prefix HEX with 0x or binary with 0b.",
    endian: "Enter 2, 4 or 8 HEX bytes.",
    nmea: "Enter an ASCII NMEA sentence body.",
    parameters:
      "Invalid parameters: use HEX addresses, quantity 0001–007D, within the register address range.",
    sent: "Demo packet added to the log. No data sent to a device.",
    loaded: "Command loaded into the demo.",
    copied: "Copied to clipboard.",
    copyFailed: "Clipboard unavailable. Select and copy the result directly.",
    empty: "Enter some data.",
    ip: "Target address",
    port: "Port",
    bind: "Listen address",
    menu: "Open navigation",
    close: "Close preview",
    expand: "Expand workspace preview",
    chart: "Two-channel sample waveform",
  },
};
let language = "zh",
  currentTool = "crc",
  format = "hex",
  sentBytes = 24,
  commandValid = true,
  copyValue = "C4 0B";
const $ = (selector) => document.querySelector(selector);
const workbench = $("#workbench"),
  stage = $(".workbench-stage"),
  dialog = $("#preview-dialog");
const samples = [
  { time: "03:48:12", direction: "TX", bytes: [1, 3, 0, 0, 0, 2, 196, 11] },
  { time: "03:48:12", direction: "RX", bytes: [1, 3, 4, 0, 1, 0, 2, 42, 50] },
  { time: "03:48:14", direction: "TX", bytes: [1, 6, 0, 1, 0, 1, 25, 202] },
  { time: "03:48:14", direction: "RX", bytes: [1, 6, 0, 1, 0, 1, 25, 202] },
  {
    time: "03:48:16",
    direction: "TX",
    bytes: [80, 111, 114, 116, 108, 121, 13, 10],
  },
  { time: "03:48:16", direction: "RX", bytes: [79, 75, 13, 10] },
];
function toast(message) {
  const element = $(".toast");
  element.textContent = message;
  element.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => {
    element.hidden = true;
  }, 3500);
}
function renderPackets() {
  $("#packets").replaceChildren(
    ...samples.slice(-6).map((packet) => {
      const row = document.createElement("tr");
      for (const [index, value] of [
        packet.time,
        packet.direction,
        format === "hex"
          ? hex(packet.bytes)
          : packet.bytes
              .map((byte) =>
                byte >= 32 && byte < 127 ? String.fromCharCode(byte) : "·",
              )
              .join(""),
      ].entries()) {
        const cell = document.createElement("td");
        cell.textContent = value;
        if (index === 1) cell.className = packet.direction.toLowerCase();
        row.append(cell);
      }
      return row;
    }),
  );
  $("#packet-count").textContent = String(samples.length);
}
function setProtocol(protocol) {
  $("#demo-protocol").value = protocol;
  const isSerial = protocol === "serial";
  $("#address-label").textContent = isSerial
    ? language === "zh"
      ? "设备路径"
      : "Device"
    : messages[language][protocol === "server" ? "bind" : "ip"];
  $("#demo-address").textContent = isSerial
    ? "/dev/cu.usbserial-01"
    : protocol === "server"
      ? "0.0.0.0"
      : "127.0.0.1";
  $("#rate-label").textContent = isSerial
    ? language === "zh"
      ? "波特率"
      : "Baud rate"
    : messages[language].port;
  $("#demo-rate").textContent = isSerial ? "115200" : "19090";
  $(".connection-pair").style.visibility = isSerial ? "visible" : "hidden";
  $("#session-name").textContent = {
    serial: "Serial 01",
    tcp: "TCP Client 01",
    server: "TCP Server 01",
    udp: "UDP 01",
  }[protocol];
  for (const button of document.querySelectorAll("[data-protocol]")) {
    const active = button.dataset.protocol === protocol;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", String(active));
  }
}
function updateCommand() {
  try {
    $("#command-preview").textContent = modbusCommand(
      Number($("#command-unit").value),
      $("#command-start").value,
      $("#command-quantity").value,
    );
    $("#command-status").textContent = "";
    commandValid = true;
  } catch {
    $("#command-preview").textContent = "—";
    $("#command-status").textContent = messages[language].parameters;
    commandValid = false;
  }
  $("#load-command").disabled = !commandValid;
}
const toolConfig = {
  crc: {
    title: ["CRC16 / Modbus", "CRC16 / Modbus"],
    description: [
      "计算数据帧的 Modbus RTU CRC16 校验值。",
      "Compute the Modbus RTU CRC16 for your data frame.",
    ],
    input: ["HEX 输入", "HEX INPUT"],
    result: ["CRC16 结果", "CRC16 RESULT"],
    wire: ["发送字节（低字节在前）", "Wire bytes (low byte first)"],
    sample: "01 03 00 00 00 02",
  },
  base: {
    title: ["进制转换", "Base conversion"],
    description: [
      "支持十进制、0x 十六进制与 0b 二进制。",
      "Decimal, 0x hexadecimal and 0b binary.",
    ],
    input: ["整数输入（最多 64 位）", "INTEGER INPUT (UP TO 64 BITS)"],
    result: ["十六进制", "HEXADECIMAL"],
    wire: ["十进制", "DECIMAL"],
    sample: "3000",
  },
  endian: {
    title: ["字节序转换", "Byte order"],
    description: [
      "反转 16、32 或 64 位数值的字节顺序。",
      "Reverse the byte order of 16, 32 or 64-bit values.",
    ],
    input: ["HEX 输入（2、4 或 8 字节）", "HEX INPUT (2, 4 OR 8 BYTES)"],
    result: ["反转字节", "REVERSED BYTES"],
    wire: ["原始大端无符号整数", "Original unsigned big-endian value"],
    sample: "12 34 56 78",
  },
  nmea: {
    title: ["NMEA 校验", "NMEA checksum"],
    description: [
      "对 $ 与 * 之间的 ASCII 字符计算 XOR。",
      "XOR the ASCII characters between $ and *.",
    ],
    input: ["NMEA 语句", "NMEA SENTENCE"],
    result: ["XOR 校验", "XOR CHECKSUM"],
    wire: ["完整语句", "COMPLETE SENTENCE"],
    sample: "GPGLL,4916.45,N,12311.12,W,225444,A",
  },
};
const drafts = Object.fromEntries(
  Object.entries(toolConfig).map(([name, config]) => [name, config.sample]),
);
function renderTool(resetInput = false) {
  const config = toolConfig[currentTool],
    index = language === "zh" ? 0 : 1;
  $("#tool-title").textContent = config.title[index];
  $("#tool-description").textContent = config.description[index];
  $("#tool-input-label").textContent = config.input[index];
  $("#result-label").textContent = config.result[index];
  $("#wire-label").textContent = config.wire[index];
  if (resetInput) $("#tool-input").value = drafts[currentTool];
  updateTool();
}
function updateTool() {
  const input = $("#tool-input").value;
  drafts[currentTool] = input;
  $("#tool-error").textContent = "";
  copyValue = "";
  try {
    if (!input.trim()) {
      $("#tool-result").textContent = "—";
      $("#wire-result").textContent = "—";
      return;
    }
    if (currentTool === "crc") {
      const result = crc16(parseHex(input));
      $("#tool-result").textContent =
        "0x" + result.toString(16).toUpperCase().padStart(4, "0");
      $("#wire-result").textContent = hex([result & 255, result >> 8]);
      copyValue = $("#wire-result").textContent;
    } else if (currentTool === "base") {
      const result = convertBase(input);
      $("#tool-result").textContent = result.hex;
      $("#wire-result").textContent = result.decimal;
      copyValue = result.hex;
    } else if (currentTool === "endian") {
      const result = reverseBytes(input);
      $("#tool-result").textContent = result.reversed;
      $("#wire-result").textContent = result.unsigned;
      copyValue = result.reversed;
    } else {
      const result = nmeaChecksum(input);
      $("#tool-result").textContent = result.checksum;
      $("#wire-result").textContent = result.sentence;
      copyValue = result.sentence;
    }
  } catch (error) {
    $("#tool-result").textContent = "—";
    $("#wire-result").textContent = "—";
    $("#tool-error").textContent =
      messages[language][error.message] || messages[language].hex;
  }
  $("#wire-result").classList.toggle("long-result", currentTool === "nmea");
}
function setLanguage(value, persist = true) {
  language = value === "en" ? "en" : "zh";
  document.documentElement.lang = language === "en" ? "en" : "zh-CN";
  const translations = language === "en" ? en : zh;
  for (const element of document.querySelectorAll("[data-i18n]"))
    element.textContent =
      translations[element.dataset.i18n] ?? zh[element.dataset.i18n];
  for (const element of document.querySelectorAll("[data-i18n-html]"))
    element.innerHTML = translations[element.dataset.i18nHtml];
  for (const button of document.querySelectorAll("[data-lang]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.lang === language),
    );
  document.title =
    language === "en"
      ? "Portly — Make sense of every byte."
      : "Portly — 读懂每个字节，掌控每次连接。";
  document.querySelector('meta[name="description"]').content =
    language === "en"
      ? "An open-source desktop workbench for Serial, TCP and UDP. Reuse commands, inspect bytes and follow up to eight waveform channels. Download for macOS and Windows."
      : "Portly 开源桌面调试工作台。在一个清晰的工作台里调试串口、TCP 和 UDP，复用参数化命令、观察多通道波形、深入检索每一帧数据。支持 macOS 与 Windows。";
  $(".menu-toggle").setAttribute("aria-label", messages[language].menu);
  $(".expand-preview").setAttribute("aria-label", messages[language].expand);
  $(".close-preview").setAttribute("aria-label", messages[language].close);
  $(".signal-chart>svg").setAttribute("aria-label", messages[language].chart);
  $("#demo-protocol").setAttribute(
    "aria-label",
    language === "en" ? "Protocol" : "通信类型",
  );
  $(".back-top").setAttribute(
    "aria-label",
    language === "en" ? "Back to top" : "返回顶部",
  );
  setProtocol($("#demo-protocol").value);
  renderTool();
  updateCommand();
  $("#demo-error").textContent = "";
  if (persist) {
    try {
      localStorage.setItem("portly-language", language);
    } catch {}
    const url = new URL(location.href);
    url.searchParams.set("lang", language);
    history.replaceState(null, "", url);
  }
}
for (const button of document.querySelectorAll("[data-lang]"))
  button.addEventListener("click", () => setLanguage(button.dataset.lang));
$(".menu-toggle").addEventListener("click", () => {
  const expanded = $(".menu-toggle").getAttribute("aria-expanded") !== "true";
  $(".menu-toggle").setAttribute("aria-expanded", String(expanded));
  $("#mobile-nav").hidden = !expanded;
});
for (const link of document.querySelectorAll("#mobile-nav a"))
  link.addEventListener("click", () => {
    $(".menu-toggle").setAttribute("aria-expanded", "false");
    $("#mobile-nav").hidden = true;
  });
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    $(".menu-toggle").setAttribute("aria-expanded", "false");
    $("#mobile-nav").hidden = true;
    $(".build-picker").open = false;
  }
});
for (const button of document.querySelectorAll("[data-protocol]"))
  button.addEventListener("click", () => setProtocol(button.dataset.protocol));
$("#demo-protocol").addEventListener("change", (event) =>
  setProtocol(event.target.value),
);
for (const button of document.querySelectorAll("[data-format]"))
  button.addEventListener("click", () => {
    format = button.dataset.format;
    for (const toggle of document.querySelectorAll("[data-format]")) {
      const active = toggle.dataset.format === format;
      toggle.classList.toggle("active", active);
      toggle.setAttribute("aria-pressed", String(active));
    }
    renderPackets();
  });
function sendDemo() {
  try {
    const bytes = parseHex($("#demo-input").value);
    if (!bytes.length) throw new Error("empty");
    if (bytes.length > 32) {
      $("#demo-error").textContent =
        language === "en"
          ? "The compact preview accepts up to 32 bytes."
          : "紧凑预览最多支持 32 字节。";
      return;
    }
    samples.push({
      time: new Date().toTimeString().slice(0, 8),
      direction: "TX",
      bytes,
    });
    if (samples.length > 100) samples.shift();
    sentBytes += bytes.length;
    $("#tx-count").textContent = String(sentBytes);
    $("#demo-error").textContent = "";
    renderPackets();
    toast(messages[language].sent);
  } catch (error) {
    $("#demo-error").textContent =
      messages[language][error.message] || messages[language].hex;
  }
}
$(".demo-send").addEventListener("click", sendDemo);
$("#demo-input").addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    sendDemo();
  }
});
for (const id of ["command-unit", "command-start", "command-quantity"])
  $("#" + id).addEventListener("input", updateCommand);
$("#load-command").addEventListener("click", () => {
  if (!commandValid) return;
  $("#demo-input").value = $("#command-preview").textContent;
  setProtocol("serial");
  $("#product").scrollIntoView({
    behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
      ? "instant"
      : "smooth",
  });
  toast(messages[language].loaded);
});
const toolTabs = [...document.querySelectorAll("[data-tool]")];
function activateTool(button) {
  for (const tab of toolTabs) {
    const active = tab === button;
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
  }
  currentTool = button.dataset.tool;
  $("#lab-panel").setAttribute("aria-labelledby", button.id);
  renderTool(true);
}
for (const button of toolTabs) {
  button.addEventListener("click", () => activateTool(button));
  button.addEventListener("keydown", (event) => {
    if (
      ![
        "ArrowRight",
        "ArrowLeft",
        "ArrowDown",
        "ArrowUp",
        "Home",
        "End",
      ].includes(event.key)
    )
      return;
    event.preventDefault();
    const index = toolTabs.indexOf(button),
      next =
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? toolTabs.length - 1
            : (index +
                (["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1) +
                toolTabs.length) %
              toolTabs.length;
    activateTool(toolTabs[next]);
    toolTabs[next].focus();
  });
}
$("#tool-input").addEventListener("input", updateTool);
$("#clear-tool").addEventListener("click", () => {
  $("#tool-input").value = "";
  updateTool();
  $("#tool-input").focus();
});
$("#copy-result").addEventListener("click", async () => {
  if (!copyValue) {
    toast($("#tool-error").textContent || messages[language].empty);
    return;
  }
  try {
    await navigator.clipboard.writeText(copyValue);
    toast(messages[language].copied);
  } catch {
    toast(messages[language].copyFailed);
  }
});
$(".expand-preview").addEventListener("click", () => {
  $("#expanded-workbench").append(workbench);
  dialog.showModal();
});
$(".close-preview").addEventListener("click", () => dialog.close());
dialog.addEventListener("close", () => {
  stage.prepend(workbench);
  $(".expand-preview").focus();
});
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) {
    const bounds = dialog.getBoundingClientRect();
    if (
      event.clientX < bounds.left ||
      event.clientX > bounds.right ||
      event.clientY < bounds.top ||
      event.clientY > bounds.bottom
    )
      dialog.close();
  }
});
document.addEventListener("click", (event) => {
  if (!event.target.closest(".build-picker")) $(".build-picker").open = false;
});
let preferred;
try {
  preferred = localStorage.getItem("portly-language");
} catch {}
setLanguage(
  new URLSearchParams(location.search).get("lang") || preferred || "zh",
  false,
);
renderPackets();
// A same-origin manifest is generated at deployment; no API quota or third-party script is needed at runtime.
fetch("./release.json")
  .then((response) => {
    if (!response.ok) throw new Error("manifest");
    return response.json();
  })
  .then((release) => {
    if (!/^v\d+\.\d+\.\d+$/.test(release.version)) return;
    for (const element of document.querySelectorAll("[data-version]"))
      element.textContent = release.version;
    const prefix =
      "https://github.com/IceBigPig/portly/releases/download/" +
      release.version +
      "/";
    for (const link of document.querySelectorAll("[data-asset]")) {
      const url = release.assets?.[link.dataset.asset];
      if (typeof url === "string" && url.startsWith(prefix)) link.href = url;
    }
  })
  .catch(() => {
    /* Keep the verified version and links embedded in the page. */
  });
