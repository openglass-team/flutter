class AiConfig {
  // 智谱 GLM-4V — 图片识别 (免费)
  static const String zhipuUrl = 'https://open.bigmodel.cn/api/paas/v4/chat/completions';
  static const String zhipuKey = 'YOUR_ZHIPU_API_KEY';
  static const String zhipuModel = 'glm-4v-flash';

  // 通义千问 Realtime — STT 语音转写 (WebSocket)
  // SDK 默认 endpoint: wss://dashscope.aliyuncs.com/api-ws/v1/realtime
  static const String qwenRealtimeUrl = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';
  static const String qwenRealtimeKey = 'sk-ws-H.EIYRXRL.XGza.MEUCIQD5km_OeTxBhTgpHewEjtGOumvWfzjwkiQSjTZMeVoRugIgc2DVbbVxQ0MQWyh9QLVh8DMghV1lJDFfrYs0PUO7Gbw';
  static const String qwenModel = 'qwen3-omni-flash-realtime';

  // 通义千问 Chat — 会议摘要 (OpenAI 兼容)
  static const String qwenChatUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
  static const String qwenChatKey = 'YOUR_QWEN_API_KEY';
  static const String qwenChatModel = 'qwen-plus';

  // Ollama — PC 本地备用
  static const String ollamaUrl = 'http://192.168.137.1:11434/api/generate';
  static const String ollamaModel = 'llava:13b';
}
