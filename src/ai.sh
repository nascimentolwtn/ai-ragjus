#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Integração com Ollama (Embeddings & Chat com Auto-recuperação)
# =========================================================================

# Cores ANSI para feedback visual do auto-healing
# Em modo NON_INTERACTIVE (interface Web) as cores são suprimidas para que
# apenas JSON limpo chegue ao consumidor (ver perguntar_ollama/gerar_embedding).
if [ "$NON_INTERACTIVE" = "1" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    GRAY=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    GRAY='\033[0;90m'
    NC='\033[0m'
fi

# Tags usadas pelos modelos de raciocínio (deepseek-r1, qwq, etc.) para
# delimitar o bloco de "pensamento" antes da resposta final.
readonly TAG_PENSAMENTO_ABRE='<think>'
readonly TAG_PENSAMENTO_FECHA='</think>'

# Resolve a janela de contexto (num_ctx) a partir do modelo configurado,
# quando CONTEXT_WINDOW="auto" no config.conf. Consulta MODELO_CONTEXT_MAP
# (declarado em src/config.sh) - sem chamadas de rede, apenas uma tabela de
# valores conhecidos. Chamada uma única vez por carregar_configuracoes(),
# no load da config; perguntar_ollama() só enxerga o valor já resolvido.
# Uso: detect_model_context "<modelo>" "<CONTEXT_WINDOW configurado>"
detect_model_context() {
    local modelo="$1"
    local configurado="$2"

    # Valor explícito no config.conf: nada a detectar, apenas repassa.
    if [ "$configurado" != "auto" ]; then
        echo "$configurado"
        return 0
    fi

    if [ -n "${MODELO_CONTEXT_MAP[$modelo]+x}" ]; then
        echo "${MODELO_CONTEXT_MAP[$modelo]}"
    else
        # Fallback conservador para modelos ausentes do mapa.
        echo 8192
    fi
}

# Gera o vetor de embedding para um bloco de texto (com auto-recuperação de modelo ausente)
gerar_embedding() {
    local texto="$1"

    # Valida parâmetros globais carregados
    if [ -z "$OLLAMA_URL_EMBEDDING" ] || [ -z "$MODELO_EMBEDDING" ]; then
        echo "Erro: OLLAMA_URL_EMBEDDING ou MODELO_EMBEDDING não estão definidos." >&2
        return 1
    fi

    # Codifica o texto de forma segura para JSON usando jq
    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_EMBEDDING" --arg prompt "$texto" '{"model": $model, "prompt": $prompt}')

    # Faz a requisição à API de embeddings do Ollama
    local response
    response=$(curl -s -X POST "$OLLAMA_URL_EMBEDDING/api/embeddings" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>/dev/null || echo "")

    # Trata respostas de erro do Ollama
    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        local err_msg
        err_msg=$(echo "$response" | jq -r '.error // empty' 2>/dev/null || echo "")
        
        # Se for erro de modelo ausente (not found)
        if echo "$err_msg" | grep -iq "not found"; then
            if [ "$NON_INTERACTIVE" = "1" ]; then
                jq -cn --arg msg "Modelo de embedding '$MODELO_EMBEDDING' não encontrado no Ollama." '{type:"error", content:$msg}' >&2
                return 1
            fi

            echo -e "\n${YELLOW}[AVISO] O modelo de indexação '$MODELO_EMBEDDING' não foi encontrado no seu Ollama.${NC}" >&2
            local baixar_embed
            read -p "Deseja realizar o download dele automaticamente agora? (~270MB) (s/n): " baixar_embed < /dev/tty

            if [ "$baixar_embed" = "s" ] || [ "$baixar_embed" = "S" ]; then
                echo -e "${BLUE}Baixando nomic-embed-text...${NC}" >&2
                curl -d "{\"name\": \"$MODELO_EMBEDDING\"}" "$OLLAMA_URL/api/pull" >&2
                echo -e "\n${GREEN}[OK] Modelo de embedding instalado! Reexecutando indexação...${NC}" >&2

                # Chamada recursiva após o download
                gerar_embedding "$texto"
                return $?
            fi
        fi

        # Se falhar e não puder recuperar
        [ -z "$err_msg" ] && err_msg="Falha de comunicação com o Ollama"
        if [ "$NON_INTERACTIVE" = "1" ]; then
            jq -cn --arg msg "Erro ao gerar embedding: $err_msg" '{type:"error", content:$msg}' >&2
        else
            echo "Erro ao gerar embedding: $err_msg" >&2
        fi
        return 1
    fi

    # Extrai o array de embeddings
    echo "$response" | jq -c '.embedding'
}

# Imprime o texto do stream do CLI, tingindo de cinza o conteúdo entre
# <think>...</think> (raciocínio de modelos como deepseek-r1/qwq) e mantendo
# o verde padrão para o restante da resposta. Só é chamada no modo interativo
# (NON_INTERACTIVE=1 já recebe as tags cruas no JSON e deixa a renderização
# a cargo do frontend web, que faz o mesmo tipo de parsing em chat.js).
#
# Os tokens chegam em pedaços arbitrários (não alinhados com as tags), então
# o texto é acumulado em $STREAM_BUFFER e só é impresso quando temos certeza
# de que não é o prefixo de uma tag ainda incompleta.
STREAM_PENSANDO=false
STREAM_BUFFER=""

_imprimir_stream_com_pensamento() {
    STREAM_BUFFER+="$1"

    while true; do
        local tag cor
        if [ "$STREAM_PENSANDO" = false ]; then
            tag="$TAG_PENSAMENTO_ABRE"
            cor="$GREEN"
        else
            tag="$TAG_PENSAMENTO_FECHA"
            cor="$GRAY"
        fi

        if [[ "$STREAM_BUFFER" == *"$tag"* ]]; then
            local antes="${STREAM_BUFFER%%"$tag"*}"
            [ -n "$antes" ] && echo -ne "${cor}${antes}${NC}"
            STREAM_BUFFER="${STREAM_BUFFER#*"$tag"}"
            [ "$STREAM_PENSANDO" = false ] && STREAM_PENSANDO=true || STREAM_PENSANDO=false
            continue
        fi

        # Sem tag completa no buffer: imprime tudo, exceto um possível prefixo
        # parcial da tag no final (para não cortar "<thi" no meio da tela).
        local manter=0 tam_max=${#STREAM_BUFFER} l
        [ "$tam_max" -gt ${#tag} ] && tam_max=${#tag}
        for (( l=tam_max; l>=1; l-- )); do
            if [ "${STREAM_BUFFER: -$l}" = "${tag:0:$l}" ]; then
                manter=$l
                break
            fi
        done

        local seguro_len=$(( ${#STREAM_BUFFER} - manter ))
        [ "$seguro_len" -gt 0 ] && echo -ne "${cor}${STREAM_BUFFER:0:$seguro_len}${NC}"
        STREAM_BUFFER="${STREAM_BUFFER: -$manter}"
        [ "$manter" -eq 0 ] && STREAM_BUFFER=""
        break
    done
}

# Envia o prompt montado para o Ollama em tempo real (com loop de retry / auto-recuperação)
perguntar_ollama() {
    local prompt="$1"

    if [ -z "$OLLAMA_URL" ] || [ -z "$MODELO_IA" ]; then
        echo "Erro: OLLAMA_URL ou MODELO_IA não estão definidos." >&2
        return 1
    fi

    # CONTEXT_WINDOW vira num_ctx no payload: sem isso o Ollama ignora a
    # config e usa o padrão de 4096, truncando o prompt silenciosamente
    # (ver .claude/plans/flask_gui_context_window_monitor.md).
    local ctx_window="${CONTEXT_WINDOW:-16384}"

    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_IA" --arg prompt "$prompt" --argjson temp "$TEMPERATURA" --argjson ctx "$ctx_window" '{"model": $model, "prompt": $prompt, "stream": true, "options": {"temperature": $temp, "num_ctx": $ctx}}')

    # Reseta o estado do buffer de <think> a cada nova pergunta.
    STREAM_PENSANDO=false
    STREAM_BUFFER=""

    while true; do
        local response_started=false
        local has_error=false
        local should_retry=false
        local tmp_err
        tmp_err=$(mktemp 2>/dev/null || echo "/tmp/ollama_err.txt")

        # Executa a chamada em streaming e processa linha a linha (suporta EOF sem newline)
        while IFS= read -r line || [ -n "$line" ]; do
            if [ -n "$line" ]; then
                # Verifica se há mensagem de erro no JSON retornado
                local erro
                erro=$(echo "$line" | jq -r '.error // empty' 2>/dev/null || echo "")
                if [ -n "$erro" ]; then
                    # Se o modelo não foi encontrado (not found)
                    if echo "$erro" | grep -iq "not found"; then
                        if [ "$NON_INTERACTIVE" = "1" ]; then
                            jq -cn --arg msg "Modelo '$MODELO_IA' não encontrado no Ollama." '{type:"error", content:$msg}'
                            has_error=true
                            break
                        fi

                        echo -e "\n${YELLOW}[AVISO] O modelo lógico '$MODELO_IA' não foi encontrado no seu Ollama.${NC}" >&2
                        local baixar_ia
                        read -p "Deseja realizar o download dele automaticamente agora? (s/n): " baixar_ia < /dev/tty
                        if [ "$baixar_ia" = "s" ] || [ "$baixar_ia" = "S" ]; then
                            echo -e "${BLUE}Baixando o modelo '$MODELO_IA'... Isso pode levar alguns minutos.${NC}" >&2
                            curl -d "{\"name\": \"$MODELO_IA\"}" "$OLLAMA_URL/api/pull" >&2
                            echo -e "\n${GREEN}[OK] Modelo instalado! Reprocessando sua pergunta...${NC}\n" >&2
                            should_retry=true
                            break
                        fi
                    fi

                    # Outros erros comuns
                    if [ "$NON_INTERACTIVE" = "1" ]; then
                        jq -cn --arg msg "$erro" '{type:"error", content:$msg}'
                    else
                        echo -e "\n${RED}[Erro do Ollama]: $erro${NC}" >&2
                    fi
                    has_error=true
                    break
                fi

                local token
                token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null || echo -n "")
                if [ -n "$token" ]; then
                    if [ "$NON_INTERACTIVE" = "1" ]; then
                        jq -cn --arg t "$token" '{type:"token", content:$t}'
                    else
                        _imprimir_stream_com_pensamento "$token"
                    fi
                    response_started=true
                fi

                # Última linha do streaming (done:true) traz as contagens
                # exatas de tokens usadas pelo Ollama - emite como evento
                # "stats" para o monitor de janela de contexto da interface
                # web substituir a estimativa por caracteres pelo valor real.
                local is_done
                is_done=$(echo "$line" | jq -r '.done // false' 2>/dev/null || echo "false")
                if [ "$is_done" = "true" ] && [ "$NON_INTERACTIVE" = "1" ]; then
                    echo "$line" | jq -c '{type:"stats", prompt_eval_count: (.prompt_eval_count // null), eval_count: (.eval_count // null)}' 2>/dev/null || true
                fi
            fi
        done < <(curl -s -N -X POST "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "$json_payload" 2>"$tmp_err" || echo "")

        rm -f "$tmp_err" 2>/dev/null || true

        # Se agendou retry, roda o loop principal novamente
        if [ "$should_retry" = true ]; then
            STREAM_PENSANDO=false
            STREAM_BUFFER=""
            continue
        fi

        # Escoa qualquer texto retido no buffer (ex: tag parcial nunca
        # completada porque o stream terminou no meio dela).
        if [ "$NON_INTERACTIVE" != "1" ] && [ -n "$STREAM_BUFFER" ]; then
            local cor_final="$GREEN"
            [ "$STREAM_PENSANDO" = true ] && cor_final="$GRAY"
            echo -ne "${cor_final}${STREAM_BUFFER}${NC}"
            STREAM_BUFFER=""
        fi

        # Se nada foi impresso, diagnostica a falha
        if [ "$response_started" = false ] && [ "$has_error" = false ]; then
            if [ "$NON_INTERACTIVE" = "1" ]; then
                jq -cn --arg msg "Nenhuma resposta foi retornada pelo Ollama. Verifique se o modelo '$MODELO_IA' está carregado corretamente e se há memória RAM livre suficiente." '{type:"error", content:$msg}'
            else
                echo -e "${RED}[Erro]: Nenhuma resposta foi retornada pelo Ollama.${NC}" >&2
                echo -e "${RED}Verifique se o modelo '$MODELO_IA' está carregado corretamente e se há memória RAM livre suficiente.${NC}" >&2
            fi
        fi

        break
    done

    # Quebra de linha ao final do streaming (apenas na CLI interativa; o modo
    # NON_INTERACTIVE já emite eventos JSON linha-a-linha e não precisa disso)
    [ "$NON_INTERACTIVE" = "1" ] || echo ""
}

# Camada de clarificação de prompt: reescreve pedidos curtos/ambíguos do
# usuário (ex.: "dobre esse texto") em uma instrução mais detalhada antes da
# geração final, para compensar modelos menores que tendem a interpretar
# esses pedidos de forma literal/matemática em vez de gerar conteúdo novo.
# A busca vetorial nunca usa o resultado desta função - só a pergunta
# original é usada para recuperar trechos, evitando viés de retrieval.
#
# Como o bloco <think> resultante precisa ser impresso no stdout real do
# stream (para chegar ao terminal/SSE na ordem certa) e a query detalhada
# precisa ser lida pelo chamador, o retorno não pode ser feito via $(...)
# (perderia o efeito de impressão). Por isso o texto detalhado fica em
# $DETALHAMENTO_QUERY após a chamada, seguindo o mesmo padrão de estado
# global já usado por STREAM_PENSANDO/STREAM_BUFFER.
DETALHAMENTO_QUERY=""

detalhar_prompt_usuario() {
    local query="$1"
    DETALHAMENTO_QUERY="$query"

    # Atalho para saudações/agradecimentos triviais: nada a clarificar aqui, e
    # mandar isso para o modelo só gera latência e risco de o pedido "reescreva
    # isso" se confundir com o próprio conteúdo do pedido (ver caso "olá", que
    # gerava uma resposta sobre a tarefa de reescrita em vez de um cumprimento).
    local query_norm
    query_norm=$(echo "$query" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[!?.,]*$//')
    case "$query_norm" in
        oi|olá|ola|hello|hi|hey|opa|eae|"e aí"|eai|"bom dia"|"boa tarde"|"boa noite"|obrigado|obrigada|obg|valeu|thanks|"thank you"|thx|tchau|bye|blz|beleza|"tudo bem"|"tudo bom"|"como vai"|"how are you"|teste|test)
            return 0
            ;;
    esac

    if [ -z "$OLLAMA_URL" ] || [ -z "$MODELO_IA" ]; then
        return 1
    fi

    local sistema="Você é uma camada de pré-processamento de prompts, não o assistente que responde ao usuário. Sua tarefa é reescrever o pedido abaixo apenas quando ele for ambíguo ou incompleto sobre o que o usuário realmente quer. Não responda ao pedido - apenas reescreva-o (ou repita-o sem alterações, se já estiver claro).

Regras (em ordem de prioridade):
1. Se o pedido envolver mudar o tamanho ou a forma de um texto (aumentar, dobrar, expandir, ampliar, encurtar, reduzir, cortar pela metade, resumir ou reescrever), SEMPRE reescreva deixando explícito que isso significa reescrever o conteúdo de forma fluida e coesa (adicionando profundidade ou condensando ideias, conforme o pedido) - nunca contar palavras, cortar o texto arbitrariamente no meio de uma frase, ou simplesmente repetir/truncar trechos literalmente. Isso vale mesmo que o pedido pareça simples e direto - o risco de execução mecânica mora justamente nesses pedidos curtos.
2. Para qualquer outro pedido que já seja claro, direto ou simples (saudações, perguntas objetivas, comandos triviais fora do escopo da regra 1), responda repetindo o pedido original exatamente como foi escrito, sem adicionar nada.
3. Não invente requisitos que não estejam implícitos no pedido original. Nunca inclua, na sua resposta, instruções sobre como você mesmo deve reescrever o pedido - a resposta é só o pedido em si (original ou detalhado), nunca uma descrição da tarefa de reescrita.
4. Responda apenas com o pedido (original ou reescrito) - sem comentários, sem explicações, sem repetir estas regras.

Pedido do usuário:
$query"

    local ctx_window="${CONTEXT_WINDOW:-16384}"
    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_IA" --arg prompt "$sistema" --argjson temp "$TEMPERATURA" --argjson ctx "$ctx_window" \
        '{"model": $model, "prompt": $prompt, "stream": false, "options": {"temperature": $temp, "num_ctx": $ctx}}')

    local response bruto
    response=$(curl -s -X POST "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>/dev/null || echo "")
    bruto=$(echo "$response" | jq -r '.response // empty' 2>/dev/null || echo "")
    bruto=$(echo "$bruto" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Falha silenciosa: segue com a query original, sem bloquear o fluxo principal
    [ -z "$bruto" ] && return 1

    # Se MODELO_IA for um modelo de raciocínio (deepseek-r1, qwq, lfm2.5, etc.),
    # $bruto já vem com seu próprio bloco <think>...</think> embutido antes do
    # texto reescrito. Separa as duas partes: o raciocínio é mantido só para
    # exibição (útil para comparar a qualidade de "pensamento" entre modelos),
    # mas NUNCA repassado adiante - colar o rascunho bruto na "Pergunta do
    # Usuário" da geração final reintroduziria justamente o tipo de raciocínio
    # matemático-literal que esta camada existe para evitar. $detalhado (só o
    # pedido reescrito) é o que vira DETALHAMENTO_QUERY.
    local raciocinio="" detalhado="$bruto"
    if [[ "$bruto" == *"$TAG_PENSAMENTO_ABRE"*"$TAG_PENSAMENTO_FECHA"* ]]; then
        local resto="${bruto#*"$TAG_PENSAMENTO_ABRE"}"
        raciocinio="${resto%%"$TAG_PENSAMENTO_FECHA"*}"
        detalhado="${resto#*"$TAG_PENSAMENTO_FECHA"}"
        raciocinio=$(echo "$raciocinio" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        detalhado=$(echo "$detalhado" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # Segurança: se o strip esvaziar o texto reescrito, cai de volta ao
        # bruto inteiro em vez de deixar DETALHAMENTO_QUERY vazio.
        [ -z "$detalhado" ] && detalhado="$bruto"
    fi

    local conteudo_pensamento="$detalhado"
    [ -n "$raciocinio" ] && conteudo_pensamento="$raciocinio

$detalhado"

    local bloco_pensamento="${TAG_PENSAMENTO_ABRE}
${conteudo_pensamento}
${TAG_PENSAMENTO_FECHA}

"

    if [ "$NON_INTERACTIVE" = "1" ]; then
        jq -cn --arg t "$bloco_pensamento" '{type:"token", content:$t}'
    else
        _imprimir_stream_com_pensamento "$bloco_pensamento"
        STREAM_PENSANDO=false
        STREAM_BUFFER=""
        echo ""
    fi

    DETALHAMENTO_QUERY="$detalhado"
}
