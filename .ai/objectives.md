# Product Objectives & Scope

## Visão

Advogados lidam com dados extremamente confidenciais (segredo de justiça, dados de clientes, contratos) e muitos têm pavor de enviar esses arquivos para nuvens de terceiros. Um sistema CLI (Command Line Interface), no estilo clássico de "tela verde", que roda 100% offline, resolve o problema da privacidade e traz um charme retrô incrível.

O objetivo não é só criar essa interface "tela verde" ininterrupta, mas usar ferramentas como dialog, whiptail ou um loop contínuo de select/read no Bash.

O script lê PDFs, TXT, CSV, DOCX e PPTX pesados em ultra velocidade, de forma offline, mandar para o Ollama ativo localmente para poder processar.

Isso deve funcionar em velocidade extrema no terminal, não pode usar o Bash puro para ler os arquivos (o Bash é lento com arquivos binários). Usar o script .sh como o maestro que gerencia ferramentas em segundo plano, escritas em linguagens de alta performance.

Aqui está o "segredo industrial" de como isso acontece nos bastidores em 3 passos ultrarrápidos:

## Core Features

### Feature 1: A Extração de Texto Textual (Ultra velocidade)

Um arquivo .docx ou .pdf é pesado porque contém imagens, formatação, fontes e metadados. Para a IA, só importa o texto limpo. O seu script .sh vai usar ferramentas CLI binárias que extraem o texto em milissegundos:

- - Para PDFs (Livros de leis e Jurisprudências): Usamos o pdftotext (da biblioteca poppler-utils). Ele ignora imagens e transforma um PDF de 500 páginas em um arquivo de texto plano (.txt) em menos de 2 segundos.

- - Para DOCX (Processos e Contratos): Usamos o pandoc ou o docx2txt. Eles abrem a estrutura XML do arquivo do Word e extraem o texto instantaneamente.

- - Para PPTX: O próprio pandoc consegue extrair os textos dos slides de forma linear.

O script faz isso uma única vez para cada arquivo e salva uma cópia em texto limpo em uma pasta oculta de "cache" (.cache_rag/).

### Feature 2: O "Fatiamento" (Chunking)

Modelos de IA locais têm um limite de memória (janela de contexto). Você não pode enviar um livro de Direito Constitucional inteiro de uma vez para o Ollama. O script pega aquele texto limpo gerado no Passo 1 e o "fatia" em pedaços menores (ex: parágrafos de 1.000 caracteres, com uma sobreposição de 200 caracteres para não perder o sentido).

### Feature 3: O Indexador Vetorial Offline (A Mágica da Velocidade)

Para buscar o processo ou a lei certa em milissegundos sem usar internet, o script .sh precisa de um Banco de Dados Vetorial CLI.

Como estamos fazendo um software open-source leve, a melhor estratégia é embutir um binário em Go junto com o seu script (ou instalar via gerenciador de pacotes). Uma escolha genial para isso é usar o llm (com o plugin llm-embed-misskey ou similar) ou uma ferramenta como chromadb via CLI.

### O processo de busca funciona assim:

- Indexação (Ocorre quando o advogado aponta a pasta): O script passa os pedaços de texto para o Ollama usando um modelo de Embedding (como o nomic-embed-text, que é micro e hiper-rápido). O Ollama transforma cada parágrafo em uma linha de números (vetor) que representa o significado daquela lei. Esses números são salvos em um arquivo de banco de dados local (como o SQLite ou um arquivo binário indexado).

- A Busca (Quando o advogado faz a pergunta): * O advogado digita no terminal verde: "Qual o prazo de contestação para o caso do cliente João?"

- - O script transforma essa pergunta em números (vetor) usando o Ollama (leva 0.05 segundos).

- - O mecanismo de busca faz um cálculo matemático matemático ultra-rápido comparando os números da pergunta com os números de todos os milhares de parágrafos salvos no banco local.

- - Ele encontra os 3 ou 4 parágrafos mais idênticos em significado (mesmo que não usem as mesmas palavras exatas).

## O Fluxo Final no Terminal Verde

Quando o advogado digita a pergunta e dá Enter, o script .sh faz o seguinte em menos de 3 segundos:

1. Pega a pergunta do advogado.

2. Faz a busca matemática no arquivo de vetores local e traz os textos das leis/processos relevantes.

3. Monta o prompt escondido: "Você é um assistente jurídico. Baseado nestes documentos [Textos Achados], responda: [Pergunta do Advogado]".

4. Envia esse prompt via API local (curl -d ... http://localhost:11434) para o Ollama (rodando um modelo focado em lógica como llama3 ou qwen2.5:7b).

5. O Ollama processa e o script exibe a resposta na tela verde, simulando o texto digitando letra por letra para dar o efeito clássico de terminal.

### Como empacotar isso no GitHub?

Você criará um repositório onde o setup.sh instala as dependências necessárias no computador do advogado (o Ollama, o poppler-utils para ler PDFs, e o pandoc). Depois de instalado, o aplicativo roda direto por um comando como ./jus.sh.

Pensando na experiência de um advogado (que geralmente não é um usuário avançado de terminal), o ideal é que o setup.sh seja o mais "mágico" e automatizado possível, mas que o aplicativo dê total flexibilidade depois.

A melhor abordagem técnica para um projeto open-source desse tipo é uma estratégia híbrida: o script define uma estrutura padrão automática para quem quer apenas testar rápido, mas permite configurar caminhos personalizados.

Aqui está como estruturar isso de forma genial e prática:

1. A Estrutura de Pastas Padrão (O "Modo Automático")

Quando o usuário executa o setup.sh, o próprio script cria uma estrutura organizada dentro do diretório onde ele foi instalado (ou na pasta Home do usuário).

A estrutura ideal no GitHub seria algo assim:

ai-ragj/
├── jus.sh              # O aplicativo principal (a tela verde)
├── setup.sh            # O instalador de dependências
├── config.conf         # Arquivo de texto que guarda as configurações (ex: caminhos)
├── docs/               # PASTA PADRÃO PARA OS PDFs E DOCX (Criada pelo setup)
│   ├── leis/
│   ├── processos/
│   └── contratos/
└── .cache_vetorial/    # Pasta oculta onde ficam os textos limpos e o banco de dados

No final do setup.sh, o script pode exibir uma mensagem na tela:

"Instalação concluída! Criamos uma pasta chamada documentos_rag. Basta arrastar os seus arquivos de leis, processos e contratos para dentro dela e rodar ./jus.sh."

2. Como gerenciar isso dinamicamente na "Tela Verde"
Para tornar o aplicativo realmente profissional e usável, você não deve forçar o usuário a abrir ou editar o código do arquivo .sh para mudar o caminho da pasta.

Em vez disso, use o arquivo config.conf para salvar as preferências. Quando o advogado abrir o aplicativo (./jus.sh), a interface de terminal pode oferecer um Menu de Configurações:

=========================================================================
                    AI RAGJUS v1.0  -  CONFIGURAÇÕES
=========================================================================

  1) Definir pasta de documentos        [ Atual: ./docs ]
  2) Alterar modelo da IA local         [ Atual: llama3 ]
  3) Alterar IP do Servidor             [ Atual: http://localhost:11434 ]
  4) Forçar Reindexação (Limpar Cache)
  5) Menu Principal
  6) Sair

=========================================================================
Digite a opção desejada:

---

Se o usuário escolher a Opção 1, o script usa o comando read -p do Bash para capturar o novo caminho:

read -p "Digite o caminho completo da pasta (ex: /Users/advogado/Documentos/Processos): " NOVO_CAMINHO

O script valida se essa pasta realmente existe no computador (if [ -d "$NOVO_CAMINHO" ]) e salva esse caminho dentro do config.conf. A partir desse momento, o sistema passa a ler aquela pasta do cliente, não importa onde o script .sh esteja instalado.

### Como o Script faz a leitura rápida com o arquivo de configuração
Toda vez que o programa inicia ou o usuário digita uma pergunta, o script lê o arquivo de configuração em segundo plano para saber onde buscar os arquivos. O fluxo de código jus.sh seria basicamente este:

``` bash
#!/bin/bash

# 1. Carrega as configurações do usuário (se não existir, usa o padrão)
if [ -f "config.conf" ]; then
    source config.conf
else
    PASTA_ALVO="./docs"
fi

# 2. Varre a pasta alvo em busca de novos PDFs/DOCX
echo "Analisando arquivos em $PASTA_ALVO..."
# ... (aqui entra o código que varre, extrai texto com pdftotext e manda pro Ollama)
```

## Flexibilidade Profissional

Se o advogado já tiver uma pasta organizada com 10GB de processos no computador dele, ele não precisa mover ou copiar esses arquivos para dentro da pasta do seu programa. Ele simplesmente abre a "tela verde", cola o caminho da pasta dele e o script começa a indexar tudo offline.