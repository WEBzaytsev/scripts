// config.js — catalogue of all scripts with field definitions and metadata.
// This is the single source of truth for what each script does and what inputs it accepts.

var SCRIPTS = [
  {
    id: 'ssh-config',
    name: 'SSH Config',
    category: 'ssh',
    description: 'Добавить SSH ключ и/или изменить порт. Выключает парольную аутентификацию при добавлении ключа.',
    warnings: [
      'Оставь текущую сессию открытой. Проверь SSH в новом терминале перед закрытием.',
    ],
    fields: [
      {
        id: 'key',
        type: 'textarea',
        label: 'SSH публичный ключ',
        placeholder: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host',
        optional: true,
        monospace: true,
        rows: 3,
        help: 'Оставь пустым если нужно только изменить порт.',
      },
      {
        id: 'portMode',
        type: 'radio',
        label: 'Режим порта',
        options: [
          { value: 'none',   label: 'Без изменений' },
          { value: 'random', label: 'Случайный (10000–65000)' },
          { value: 'fixed',  label: 'Фиксированный' },
        ],
        default: 'none',
      },
      {
        id: 'port',
        type: 'number',
        label: 'Порт',
        placeholder: '22222',
        min: 1024,
        max: 65535,
        showIf: { field: 'portMode', value: 'fixed' },
      },
      {
        id: 'yes',
        type: 'checkbox',
        label: 'Пропустить подтверждения (--yes)',
        default: false,
      },
    ],
  },

  {
    id: 'revoke-ssh-keys',
    name: 'Revoke SSH Keys',
    category: 'ssh',
    description: 'Экстренный сброс всех авторизованных SSH ключей. С новым ключом — оставляет только его.',
    warnings: [],
    fields: [
      {
        id: 'key',
        type: 'textarea',
        label: 'Новый SSH публичный ключ (рекомендуется)',
        placeholder: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host',
        optional: true,
        monospace: true,
        rows: 3,
        help: 'Будет установлен ПЕРВЫМ, затем все остальные ключи удалятся.',
      },
      {
        id: 'yes',
        type: 'checkbox',
        label: 'Пропустить подтверждения (--yes)',
        default: true,
      },
      {
        id: 'killSessions',
        type: 'checkbox',
        label: 'Завершить чужие SSH-сессии (--kill-sessions)',
        default: false,
      },
      {
        id: 'regenHostKeys',
        type: 'checkbox',
        label: 'Перегенерировать host-ключи сервера (--regen-host-keys)',
        default: false,
      },
      {
        id: 'cleanupBefore',
        type: 'checkbox',
        label: 'Удалить старую скачанную копию скрипта перед запуском',
        default: true,
        help: 'Нужно если ранее скачивал скрипт вручную — иначе curl может выполнить старую версию.',
      },
      {
        id: 'cleanupAfter',
        type: 'checkbox',
        label: 'Удалить скачанную копию скрипта после запуска',
        default: true,
        help: 'Удаляет файл, если скрипт был скачан, а не запущен через pipe.',
      },
    ],
  },

  {
    id: 'ssh-keygen',
    name: 'Генерация SSH ключа',
    category: 'ssh',
    description: 'Сгенерировать новую пару SSH ключей локально на твоей машине (не на сервере).',
    warnings: [],
    isLocalCommand: true,
    fields: [
      {
        id: 'email',
        type: 'text',
        label: 'Email / комментарий',
        placeholder: 'user@example.com',
        optional: false,
      },
      {
        id: 'filename',
        type: 'text',
        label: 'Имя файла',
        placeholder: 'id_ed25519',
        optional: true,
        help: 'По умолчанию: ~/.ssh/id_ed25519',
      },
    ],
  },

  {
    id: 'docker-aliases',
    name: 'Docker Aliases',
    category: 'docker',
    description: 'Установить docker compose алиасы (dc, dcu, dcud, dcl, dcps...) в /etc/profile.d системно.',
    warnings: [],
    fields: [
      {
        id: 'action',
        type: 'radio',
        label: 'Действие',
        options: [
          { value: 'install',   label: 'Установить' },
          { value: 'uninstall', label: 'Удалить' },
          { value: 'print',     label: 'Показать содержимое' },
        ],
        default: 'install',
      },
    ],
  },

  {
    id: 'docker-monitor',
    name: 'Docker Monitor',
    category: 'docker',
    description: 'Настройка dozzle-agent и beszel-agent через docker compose. Остальные параметры вводятся интерактивно на сервере.',
    warnings: [
      'Скрипт интерактивный — оставшиеся параметры (ключ, токен, порты) вводятся прямо в терминале сервера.',
    ],
    fields: [
      {
        id: 'hubUrl',
        type: 'text',
        label: 'Beszel Hub URL',
        placeholder: 'https://monitor.example.com',
        optional: true,
        help: 'Если указать — пропустит этот вопрос при интерактивном запуске.',
      },
    ],
  },

  {
    id: 'enable-bbr',
    name: 'Enable BBR',
    category: 'network',
    description: 'Включить TCP BBR (алгоритм управления перегрузкой) и установить fq как дисциплину очереди.',
    warnings: [],
    fields: [],
  },

  {
    id: 'ufw-config',
    name: 'UFW Firewall',
    category: 'network',
    description: 'Настроить UFW: политики, SSH, HTTPS, автоопределение Xray/Remnawave/OpenVPN, доп. порты, блокировка ICMP.',
    warnings: [
      'Оставь текущую сессию открытой. Проверь SSH до закрытия.',
    ],
    fields: [
      {
        id: 'sshPort',
        type: 'text',
        label: 'SSH-порт',
        placeholder: 'auto',
        optional: true,
        help: 'Оставь пустым — определится автоматически из sshd_config.',
      },
      {
        id: 'https',
        type: 'checkbox',
        label: 'Разрешить 443/tcp (HTTPS/VPN)',
        default: true,
      },
      {
        id: 'xray',
        type: 'checkbox',
        label: 'Авто-определить порты Xray',
        default: true,
      },
      {
        id: 'remnawave',
        type: 'checkbox',
        label: 'Авто-определить порты Remnawave',
        default: true,
      },
      {
        id: 'openvpn',
        type: 'checkbox',
        label: 'Авто-определить OpenVPN (1194/udp)',
        default: true,
      },
      {
        id: 'icmpBlock',
        type: 'checkbox',
        label: 'Заблокировать ICMP ping',
        default: true,
      },
      {
        id: 'extraPorts',
        type: 'text',
        label: 'Дополнительные порты',
        placeholder: '8080,9000-9002',
        optional: true,
        help: 'Через запятую или диапазон. Разрешаются tcp+udp.',
      },
      {
        id: 'yes',
        type: 'checkbox',
        label: 'Пропустить подтверждения (--yes)',
        default: false,
      },
    ],
  },
];

var CATEGORIES = [
  { id: 'ssh',     label: 'SSH' },
  { id: 'docker',  label: 'Docker' },
  { id: 'network', label: 'Network' },
];
