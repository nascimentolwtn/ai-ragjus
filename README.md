# ⚖️ AI-RAGJus

Este projeto consiste no desenvolvimento de uma aplicação de linha de comando (CLI) open-source voltada para o mercado jurídico, projetada especificamente para operar em regime de total isolamento de rede (100% offline e air-gapped). O sistema adota uma estética clássica de terminal retrô (estilo "tela verde") e roda de forma contínua e ininterrupta em ambientes baseados em Unix e no subsistema Windows para Linux (WSL2).

O grande diferencial estratégico do produto é a garantia absoluta de privacidade de dados sensíveis — como peças processuais, contratos confidenciais e segredos de justiça —, processando todas as informações diretamente no hardware local do escritório, sem trafegar dados por nuvens ou APIs de terceiros.

---

## 🚀 Instalação Rápida (Comando Único)

Você pode instalar o **AI-RAGJus** diretamente via terminal com o comando abaixo. O instalador verificará os requisitos do sistema, dependências básicas, configurará as pastas locais e baixará os modelos necessários do Ollama de forma automática.

```bash
curl -sSL https://raw.githubusercontent.com/fraconca/ai-ragjus/main/setup.sh | bash
```

---

## 🛠️ Pré-requisitos de Sistema

Para rodar 100% offline localmente, a aplicação necessita que você tenha instalado ou instale durante o setup:

1. **Ollama**: Motor local de modelos de IA.
   * [Download do Ollama](https://ollama.com)
2. **Dependências do Terminal** (o script alertará se faltar alguma):
   * `curl`
   * `jq` (leitor e manipulador JSON)
   * `sqlite3` (persistência local)
   * `pdftotext` (via `poppler-utils` para leitura de PDFs)
   * `pandoc` (para leitura de arquivos `.docx` e `.pptx`)

### Requisitos Mínimos de Hardware:
* **Memória RAM**: Mínimo de 4GB. (Recomendado 8GB+ para rodar modelos de 7B/8B na velocidade ideal).
  * O instalador ajusta automaticamente a sugestão do modelo de IA para sistemas com menos de 8GB de RAM.

---

## 📂 Estrutura de Pastas Criada

Após a instalação, a estrutura do seu projeto será organizada da seguinte forma:

```
ai-ragjus/
├── jus.sh                  # Aplicativo maestro principal (a interface de tela verde)
├── setup.sh                # Script de provisionamento e dependências
├── config.conf             # Configurações ativas (modelo, pasta alvo, etc.)
├── docs/                   # Insira seus documentos jurídicos aqui
│   ├── contratos/
│   ├── leis/
│   └── processos/
└── .cache_vetorial/        # Banco de dados SQLite local e caches (oculto)
```

---

## 📖 Como Usar (Passo a Passo)

### Passo 1: Coloque seus documentos na pasta `docs`
Mova ou copie seus arquivos nos formatos suportados (`.pdf`, `.docx`, `.pptx`, `.txt`, `.md`, `.csv`) para dentro do diretório correspondente criado em `docs/`.

### Passo 2: Inicie o Aplicativo
Navegue até a pasta do projeto e inicie a interface de tela verde:
```bash
./jus.sh
```

### Passo 3: Sincronize/Indexe os Documentos
No menu principal do terminal, selecione a **Opção 2 (Sincronizar / Reindexar Pasta de Documentos)**. O sistema irá:
1. Ler e extrair o texto limpo de cada arquivo novo ou alterado.
2. Fatiar o texto em blocos menores (chunks).
3. Gerar os embeddings locais via Ollama.
4. Armazenar tudo com segurança no banco SQLite local.

### Passo 4: Comece a Perguntar (Chat RAG)
Selecione a **Opção 1 (Iniciar Busca Jurídica RAG)**. Digite suas dúvidas jurídicas em linguagem natural. A IA buscará os trechos mais relevantes do seu acervo no banco SQLite, montará o contexto local e responderá na hora de forma estruturada, informando os arquivos de origem.

---

## ⚙️ Configurações Personalizadas

Você pode editar o arquivo `config.conf` manualmente ou através do menu principal da CLI para ajustar:
* O modelo de IA local em uso (ex: `qwen2.5:7b`, `llama3:8b`, `qwen2.5:1.5b`).
* O caminho personalizado da pasta de documentos (caso você já possua um diretório organizado no seu computador).
* O tamanho do fatiamento (`CHUNK_SIZE`) e a sobreposição dos blocos (`CHUNK_OVERLAP`).

---

## 🔒 Segurança e Privacidade (Air-Gapped por Padrão)

A aplicação foi desenvolvida sob a filosofia de privacidade estrita. 
* Não são feitas chamadas de API externas após a fase de setup.
* Toda a indexação matemática e inferência lógica de linguagem ocorre em sua máquina local.
* Ideal para ambientes restritos e conformidade com a LGPD e o segredo de justiça.
