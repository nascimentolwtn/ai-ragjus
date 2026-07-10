#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Ingestão e Fatiamento de Documentos (Chunking)
# =========================================================================

# Extrai o texto limpo de um arquivo de acordo com sua extensão
extrair_texto_limpo() {
    local arquivo="$1"
    local extensao="${arquivo##*.}"
    extensao=$(echo "$extensao" | tr '[:upper:]' '[:lower:]')

    case "$extensao" in
        pdf)
            if command -v pdftotext &> /dev/null; then
                pdftotext "$arquivo" - 2>/dev/null || echo ""
            else
                echo "[ERRO] pdftotext não está instalado. Não foi possível ler PDF." >&2
                return 1
            fi
            ;;
        docx|pptx)
            if command -v pandoc &> /dev/null; then
                pandoc -f docx -t plain "$arquivo" 2>/dev/null || echo ""
            elif command -v docx2txt &> /dev/null && [ "$extensao" = "docx" ]; then
                docx2txt "$arquivo" - 2>/dev/null || echo ""
            else
                echo "[ERRO] pandoc ou docx2txt não instalado. Não foi possível ler DOCX/PPTX." >&2
                return 1
            fi
            ;;
        txt|md|csv)
            cat "$arquivo" 2>/dev/null || echo ""
            ;;
        *)
            echo "[AVISO] Formato de arquivo não suportado: $extensao" >&2
            return 1
            ;;
    esac
}

# Divide o texto em blocos menores (chunks) usando JQ
fatiar_texto() {
    local texto="$1"
    
    # Executa o chunking em JQ de forma ultra rápida
    jq -n \
        --arg text "$texto" \
        --argjson size "$CHUNK_SIZE" \
        --argjson overlap "$CHUNK_OVERLAP" \
        '
        [
          range(0; $text | length; $size - $overlap) as $start
          | $text[$start : $start + $size]
          | select(length > 0)
        ]
        '
}

# Compara os arquivos cadastrados no banco SQLite com o disco e remove registros órfãos
remover_arquivos_deletados_do_banco() {
    local db_path
    db_path=$(obter_db_path)

    if [ ! -f "$db_path" ]; then
        return
    fi

    # Busca os caminhos de arquivos únicos registrados no SQLite
    local arquivos_registrados
    arquivos_registrados=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks;" 2>/dev/null || echo "")

    if [ -n "$arquivos_registrados" ]; then
        # Lê linha a linha de forma resiliente
        echo "$arquivos_registrados" | while IFS= read -r arquivo_db || [ -n "$arquivo_db" ]; do
            if [ -n "$arquivo_db" ]; then
                # Se o arquivo não existir fisicamente no disco, limpa sua indexação do banco
                if [ ! -f "$arquivo_db" ]; then
                    echo -e "${YELLOW}  [Limpeza] Removendo registros de arquivo excluído do disco: $arquivo_db${NC}"
                    limpar_registros_arquivo "$arquivo_db"
                fi
            fi
        done
    fi
}

# Varre a pasta de documentos, verifica modificações via hashes e processa arquivos
sincronizar_documentos() {
    local pasta_alvo="$PASTA_ALVO"
    
    if [ ! -d "$pasta_alvo" ]; then
        echo -e "${RED}Erro: A pasta alvo '$pasta_alvo' não existe.${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}Iniciando varredura em: $pasta_alvo...${NC}"
    
    # Cria diretório de cache se não existir
    mkdir -p "$CACHE_DIR"

    # Inicializa banco SQLite (se necessário)
    inicializar_banco_vetorial

    # Executa a limpeza de arquivos órfãos (excluídos do disco) antes de indexar novos
    remover_arquivos_deletados_do_banco

    # Varre a pasta recursivamente procurando arquivos suportados
    # Ignora arquivos ocultos ou temporários (~$)
    find -L "$pasta_alvo" -type f \( -name "*.pdf" -o -name "*.docx" -o -name "*.pptx" -o -name "*.txt" -o -name "*.md" -o -name "*.csv" \) ! -name ".*" ! -name "~\$*" | while read -r arquivo; do
        
        # Calcula hash SHA-256 do arquivo para controle de cache idempotente
        local hash_atual
        if [ "$(uname -s)" = "Darwin" ]; then
            hash_atual=$(shasum -a 256 "$arquivo" | awk '{print $1}')
        else
            hash_atual=$(sha256sum "$arquivo" | awk '{print $1}')
        fi

        # Verifica se o arquivo já foi processado e não mudou
        if verificar_hash_existente "$arquivo" "$hash_atual"; then
            echo -e "  [Ignorado - Cache] $arquivo"
            continue
        fi

        echo -e "${BLUE}  [Processando] $arquivo...${NC}"
        
        # Remove registros antigos do arquivo para reindexação limpa
        limpar_registros_arquivo "$arquivo"

        # Extrai texto do arquivo
        local texto
        texto=$(extrair_texto_limpo "$arquivo" || echo "")

        if [ -z "$texto" ]; then
            echo -e "${RED}    -> Falha ao extrair texto ou arquivo vazio.${NC}" >&2
            continue
        fi

        # Fatiamento em chunks (formato de array JSON)
        local chunks_json
        chunks_json=$(fatiar_texto "$texto")
        local num_chunks
        num_chunks=$(echo "$chunks_json" | jq '. | length')

        echo "    -> Gerando embeddings para $num_chunks blocos de texto..."

        # Loop pelos chunks para gerar embeddings e salvar no banco
        for (( i=0; i<num_chunks; i++ )); do
            local chunk_texto
            chunk_texto=$(echo "$chunks_json" | jq -r --argjson idx "$i" '.[$idx]')

            # Gera embedding usando a API do Ollama
            local vetor
            vetor=$(gerar_embedding "$chunk_texto" || echo "")

            if [ -n "$vetor" ]; then
                # Salva o bloco e o vetor no banco de dados SQLite
                salvar_bloco_vetorial "$arquivo" "$hash_atual" "$i" "$chunk_texto" "$vetor"
            else
                echo -e "${RED}    [ERRO] Falha ao gerar embedding para o bloco $i.${NC}" >&2
            fi
        done
        echo -e "${GREEN}    -> Arquivo indexado com sucesso!${NC}"
    done

    echo -e "${GREEN}Varredura de documentos finalizada.${NC}"
}
