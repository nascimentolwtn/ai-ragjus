# ⚖️ AI-RAGJus

Este projeto consiste no desenvolvimento de uma aplicação de linha de comando (CLI) open-source voltada para o mercado jurídico, projetada especificamente para operar em regime de total isolamento de rede (100% offline e air-gapped). O sistema adota uma estética clássica de terminal retrô (estilo "tela verde") e roda de forma contínua e ininterrupta em ambientes baseados em Unix e no subsistema Windows para Linux (WSL2).

O grande diferencial estratégico do produto é a garantia absoluta de privacidade de dados sensíveis — como peças processuais, contratos confidenciais e segredos de justiça —, processando todas as informações diretamente no hardware local do escritório, sem trafegar dados por nuvens ou APIs de terceiros.

---

## 🚀 Instalação Rápida (Comando Único)

Você pode instalar o **AI-RAGJus** diretamente via terminal com o comando abaixo. O instalador é interativo e cuidará de todo o processo de forma automatizada e guiada.

```bash
curl -sSL https://raw.githubusercontent.com/fraconca/ai-ragjus/main/setup.sh | bash
```

---

## 🛠️ Pré-requisitos e Instalação Automática

Para funcionar 100% offline localmente, a aplicação necessita das seguintes ferramentas de sistema:

1. **Ollama**: Motor local de modelos de IA (necessário estar instalado e rodando em segundo plano. Baixe em: [ollama.com](https://ollama.com)).
2. **Dependências CLI**:
   * `pdftotext` (para extração rápida de textos de PDFs)
   * `pandoc` (para ler e processar arquivos `.docx` e `.pptx`)
   * `jq` (manipulador e decodificador JSON)
   * `sqlite3` (persistência do banco vetorial local)

### 📦 Como funciona a instalação das dependências:
O instalador (`setup.sh`) realiza uma verificação inteligente do seu ambiente:
* **Se você já possui as ferramentas instaladas:** O script detecta instantaneamente, **pula esta etapa e não realiza nenhuma readequação, reinstalação ou atualização**, garantindo rapidez.
* **Se faltar alguma ferramenta:** O script perguntará amigavelmente se deseja que a instalação seja feita de forma automática.
  * **No macOS:** Se aceito, o script valida e instala o Homebrew (se necessário) e roda `brew install poppler pandoc jq sqlite3` de forma autônoma.
  * **No Linux / WSL2:** O script instala as ferramentas usando o gerenciador de pacotes nativo `apt-get` (`sudo apt-get install`).

### Requisitos Mínimos de Hardware:
* **Memória RAM**: Mínimo de 4GB. (Recomendado 8GB+ para rodar com extrema fluidez).
  * O instalador recomenda por padrão o modelo leve **`qwen2.5:1.5b`**, garantindo que a aplicação responda de forma ultra rápida e sem travar computadores comuns.

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
1. Ler e extrair o texto limpo de cada arquivo novo ou alterado de forma idempotente (baseado no hash do arquivo).
2. Fatiar o texto em blocos menores (chunks).
3. Gerar os embeddings locais via Ollama.
4. Armazenar tudo com segurança no banco SQLite local.

### Passo 4: Comece a Perguntar (Chat RAG)
Selecione a **Opção 1 (Iniciar Busca Jurídica RAG)**. Digite suas dúvidas jurídicas em linguagem natural. A IA buscará os trechos mais relevantes do seu acervo no banco SQLite, montará o contexto local e responderá na hora de forma estruturada, informando os arquivos de origem.

---

## ⚙️ Configurações Personalizadas

Você pode editar o arquivo `config.conf` manualmente ou através do menu principal da CLI para ajustar:
* O modelo de IA local em uso (padrão: `qwen2.5:1.5b` ou outros como `llama3.2:3b`, `qwen2.5:7b`).
* O caminho personalizado da pasta de documentos.
* O tamanho do fatiamento (`CHUNK_SIZE`) e a sobreposição dos blocos (`CHUNK_OVERLAP`).

---

## 🛡️ Auto-recuperação de Modelos (Self-healing)

O sistema possui uma inteligência de **auto-recuperação (self-healing)** para garantir uma experiência livre de quebras para o usuário final:
* **Detecção Automática**: Caso o advogado altere as configurações para um modelo de IA ou embedding que não esteja atualmente baixado em seu Ollama, a aplicação detecta o erro de modelo ausente na hora de fazer a pergunta.
* **Frictionless Download**: Em vez de travar ou retornar um erro, o chat pergunta na tela se o usuário deseja efetuar o download daquele modelo de forma automática.
* **Continuidade do Fluxo**: Se aceito, o próprio sistema baixa o modelo exibindo o progresso. Assim que o download é concluído, **o chat reprocessa e responde à pergunta original automaticamente**, sem que o usuário precise reiniciar o programa ou digitar a pergunta novamente.

---

## 🔒 Segurança e Privacidade (Air-Gapped por Padrão)

A aplicação foi desenvolvida sob a filosofia de privacidade estrita. 
* Não são feitas chamadas de API externas após a fase de setup.
* Toda a indexação matemática e inferência lógica de linguagem ocorre em sua máquina local.
* Ideal para ambientes restritos e conformidade com a LGPD e o segredo de justiça.
