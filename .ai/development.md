# Development Workflow: Build & Testing

## Prerequisites
- Shell Environment: Bash v4.0 ou superior (Nativo em Linux/macOS, via WSL2 no Windows).
- Core CLI Tools: curl, jq (versão 1.6+), e poppler-utils (para o binário pdftotext).
- AI Environment: Ollama instalado e rodando localmente como serviço de segundo plano (localhost:11434).
- Modelos Mandatórios (Locais):
- - Inferência/Lógica: qwen2.5:7b ou llama3:8b
- - Vetorização/Embeddings: nomic-embed-text

## Build & Run Procedures
### Setup & Installation
O ambiente é preparado automaticamente através do script de provisionamento. Para instalar as dependências de sistema e criar a estrutura de pastas padrão, execute:

```bash
chmod +x setup.sh
./setup.sh
```

O script irá validar os requisitos de hardware (mínimo de 4GB de RAM recomendados), verificar a comunicação com o daemon do Ollama e baixar os modelos caso não estejam presentes no sistema.

### Build Procedures

Por ser uma aplicação baseada em scripts de shell interpretados e utilitários compilados nativos, não há uma etapa de compilação tradicional (build step).

A inicialização e acoplamento dos módulos (/modules/*.sh) ocorrem em tempo de execução. Para iniciar a interface clássica "tela verde", basta executar o script maestro:

```bash
chmod +x jus-app.sh
./jus.sh
```

## Testing & Verification

Os testes unitários das funções isoladas do Bash (como cálculo de hashes MD5/SHA-256 para o cache, fatiamento de texto e parsing de respostas JSON geradas pelo jq) utilizam o framework Bats-core (Bash Automated Testing System).

Comando para execução:

```bash
bats test/unit/
```

## Integration/E2E Testing

Os testes de integração validam o fluxo de ponta a ponta (LIG - Leitura, Indexação e Geração) simulando a esteira completa:

- Ingestão de um arquivo .pdf ou .docx de teste na pasta configurada em config.conf.
- Verificação se a extração gerou o texto limpo esperado no diretório oculto .cache_vetorial/.
- Disparo de uma query simulada via curl para a API do Ollama.

Comando para execução:

```bash
./test/integration/run_e2e_suite.sh
```

## Verification

Atenção Agente de IA: Antes de declarar qualquer tarefa de desenvolvimento ou refatoração como concluída, vocês devem garantir estritamente que:

- Todos os testes no bats passem sem regressões.
- Nenhuma chamada de rede externa seja adicionada aos módulos de API (o comportamento estritamente offline/air-gapped deve ser mantido).
- O tratamento de erro global (set -eo pipefail) não quebre o loop infinito da interface CLI caso o Ollama demore a responder.