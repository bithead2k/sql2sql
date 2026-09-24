# Token locations allow expressions to pass through without rewriting SQL text.
tokenize() {
    local sql=$1 i=0 n=${#1} start c next quote tag escaped depth=0 level j
    local -a stack=()
    T=() S=() E=() D=() M=() K=()
    while ((i<n)); do
        c=${sql:i:1} next=${sql:i+1:1}
        if [[ $c == [[:space:]] ]]; then ((i+=1)); continue; fi
        if [[ $c$next == '--' ]]; then
            while ((i<n)) && [[ ${sql:i:1} != $'\n' ]]; do ((i+=1)); done
            continue
        fi
        if [[ $c$next == '/*' ]]; then
            level=1; ((i+=2))
            while ((i<n && level)); do
                case ${sql:i:2} in
                    '/*') ((level+=1, i+=2));;
                    '*/') ((level-=1, i+=2));;
                    *) ((i+=1));;
                esac
            done
            ((level == 0)) || { fail 'unterminated comment'; return 1; }
            continue
        fi
        start=$i; escaped=0; quote=''; tag=''
        if [[ $c == "'" || $c == '"' ]]; then
            quote=$c
        elif [[ $c == [Ee] && $next == "'" ]]; then
            escaped=1; ((i+=1)); quote="'"
        elif [[ $c == [Uu] && ${sql:i+1:2} == '&"' ]]; then
            ((i+=2)); quote='"'
        elif [[ $c == '$' && ${sql:i} =~ ^(\$([[:alpha:]_][[:alnum:]_]*)?\$) ]]; then
            tag=${BASH_REMATCH[1]}
        fi
        local kind=symbol closed=0
        if [[ -n $quote ]]; then
            kind=literal
            [[ $quote == '"' ]] && kind=identifier
            ((i+=1))
            while ((i<n)); do
                c=${sql:i:1}
                if [[ $c == "$quote" ]]; then
                    ((i+=1))
                    if [[ ${sql:i:1} == "$quote" ]]; then ((i+=1)); else closed=1; break; fi
                elif ((escaped)) && [[ $c == \\ ]]; then ((i+=2))
                else ((i+=1)); fi
            done
            ((closed)) || { fail 'unterminated quoted token'; return 1; }
        elif [[ -n $tag ]]; then
            kind=literal; ((i+=${#tag}))
            while ((i<n)); do
                if [[ ${sql:i:${#tag}} == "$tag" ]]; then
                    ((i+=${#tag})); closed=1; break
                fi
                ((i+=1))
            done
            ((closed)) || { fail 'unterminated dollar quote'; return 1; }
        elif [[ $c == [[:alnum:]_\$] ]]; then
            kind=word
            while ((i<n)) && [[ ${sql:i:1} == [[:alnum:]_\$] ]]; do ((i+=1)); done
        else
            ((i+=1))
        fi
        j=${#T[@]}
        T+=("${sql:start:i-start}"); S+=("$start"); E+=("$i"); K+=("$kind"); M+=(-1)
        case ${T[j]} in
            '('|'[') D+=("$depth"); stack+=("$j"); ((depth+=1));;
            ')'|']')
                ((depth>0)) || { fail 'unbalanced delimiters'; return 1; }
                ((depth-=1)); D+=("$depth")
                local open=${stack[depth]}
                [[ ${T[open]}${T[j]} == '()' || ${T[open]}${T[j]} == '[]' ]] || {
                    fail 'mismatched delimiters'; return 1;
                }
                M[open]=$j; M[j]=$open; unset 'stack[depth]'
                ;;
            *) D+=("$depth");;
        esac
    done
    ((depth == 0)) || { fail 'unbalanced delimiters'; return 1; }
}

is_word() { [[ ${K[$1]:-} == word && ${T[$1]^^} == "$2" ]]; }
is_identifier() { [[ ${K[$1]:-} == identifier || ${K[$1]:-} == word && ${T[$1]} == [[:alpha:]_]* ]]; }

# Reads one identifier, including the optional Unicode escape clause.
identifier() {
    is_identifier "$pos" || { fail 'expected an SQL identifier'; return 1; }
    local begin=${S[pos]} end=${E[pos]}
    ((pos+=1))
    if is_word "$pos" UESCAPE; then
        [[ ${K[pos+1]:-} == literal ]] || { fail 'expected UESCAPE character'; return 1; }
        end=${E[pos+1]}; ((pos+=2))
    fi
    ident=${sql:begin:end-begin}
}

parse_ident_list() {
    local sql=$1 pos=0 ident
    local -a T S E D M K
    PARSED_COLUMNS=()
    tokenize "$sql" || return
    while ((pos<${#T[@]})); do
        identifier || return
        PARSED_COLUMNS+=("$ident")
        if ((pos<${#T[@]})); then
            [[ ${T[pos]} == ',' ]] || { fail 'expected a comma-separated column list'; return 1; }
            ((pos+=1))
            ((pos<${#T[@]})) || { fail 'empty column list entry'; return 1; }
        fi
    done
    ((${#PARSED_COLUMNS[@]})) || { fail 'empty column list'; return 1; }
}

canonical_ident() {
    CANONICAL=$1
    if [[ $1 == \"*\" ]]; then
        CANONICAL=${1:1:${#1}-2}
        CANONICAL=${CANONICAL//\"\"/\"}
    else
        CANONICAL=${1,,}
    fi
}

# Build OR groups of ANDed column indexes. Repeated keys are alternatives.
select_keys() {
    local spec col key_col index found group canonical j
    GROUPS_SELECTED=()
    if ((${#key_specs[@]})); then
        for spec in "${key_specs[@]}"; do
            parse_ident_list "$spec" || return
            group=''
            for key_col in "${PARSED_COLUMNS[@]}"; do
                canonical_ident "$key_col"; canonical=$CANONICAL; found=0
                for ((j=0; j<${#columns[@]}; j++)); do
                    canonical_ident "${columns[j]}"
                    if [[ $CANONICAL == "$canonical" ]]; then
                        group+=" $j"; found=1; break
                    fi
                done
                ((found)) || { fail "key column $key_col is absent from the input column list"; return 1; }
            done
            GROUPS_SELECTED+=("$group")
        done
    elif [[ $match_mode == any ]]; then
        for ((j=0; j<${#columns[@]}; j++)); do GROUPS_SELECTED+=("$j"); done
    else
        group=''
        for ((j=0; j<${#columns[@]}; j++)); do group+=" $j"; done
        GROUPS_SELECTED+=("$group")
    fi
}

# Only omit expression grouping when it is demonstrably unnecessary. Keep
# arbitrary SQL expressions grouped so boolean/comparison precedence is intact.
predicate_value() {
    local sql=$1
    local -a T S E D M K
    tokenize "$sql" || return
    PREDICATE_VALUE="($sql)"
    if [[ $sql =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] ||
       [[ ${sql^^} == NULL || ${sql^^} == TRUE || ${sql^^} == FALSE ]] ||
       { ((${#T[@]}==1)) && [[ ${K[0]} == literal ]]; } ||
       { [[ ${T[0]:-} == '(' ]] && ((M[0]==${#T[@]}-1)); }; then
        PREDICATE_VALUE=$sql
    fi
}

make_predicate() {
    local group j term joined
    PREDICATE=''
    for group in "${GROUPS_SELECTED[@]}"; do
        joined=''
        for j in $group; do
            [[ -z $joined ]] || joined+=' AND '
            if [[ $predicate_kind == values ]]; then
                if [[ ${expressions[j]^^} == DEFAULT ]]; then
                    fail "DEFAULT for matching column ${columns[j]} requires a table definition"; return 1
                else
                    predicate_value "${expressions[j]}" || return
                    term="${columns[j]} $comparison_operator $PREDICATE_VALUE"
                fi
            else
                term="\"__insert2select_target\".${columns[j]} $comparison_operator \"__insert2select_source\".\"c$j\""
            fi
            joined+=$term
        done
        [[ -z $PREDICATE ]] || PREDICATE+=' OR '
        # AND binds more tightly than OR; no group wrapper is necessary here.
        PREDICATE+=$joined
    done
}

convert_insert() {
    local sql=$1 pos=0 ident table prefix='' source_start source_end suffix i j k close begin end start value predicate_kind whole_row=0
    local -a columns=() expressions=() rows=()
    tokenize "$sql" || return
    local count=${#T[@]}
    if is_word 0 WITH; then
        while ((pos<count)); do
            if ((D[pos]==0)) && is_word "$pos" INSERT; then break; fi
            if is_word "$pos" INSERT || is_word "$pos" UPDATE || is_word "$pos" DELETE || is_word "$pos" MERGE; then
                fail 'data-modifying WITH queries cannot become a read-only SELECT'; return 1
            fi
            ((pos+=1))
        done
        ((pos<count)) || { fail 'expected a top-level INSERT after WITH'; return 1; }
        prefix=${sql:0:S[pos]}
    fi
    is_word "$pos" INSERT && is_word "$((pos+1))" INTO || {
        fail 'input must contain only INSERT INTO statements'; return 1;
    }
    ((pos+=2)); identifier || return; table=$ident
    while [[ ${T[pos]:-} == '.' ]]; do
        ((pos+=1)); identifier || return; table+=".$ident"
    done
    if is_word "$pos" AS; then ((pos+=1)); identifier || return; fi
    if [[ ${T[pos]:-} == '(' && ${T[pos+1]:-} != '(' ]] &&
       ! is_word "$((pos+1))" SELECT && ! is_word "$((pos+1))" VALUES &&
       ! is_word "$((pos+1))" WITH && ! is_word "$((pos+1))" TABLE; then
        close=${M[pos]}; ((pos+=1))
        while ((pos<close)); do
            identifier || return
            columns+=("$ident")
            if ((pos<close)); then
                [[ ${T[pos]} == ',' ]] || {
                    fail 'composite-field and array-element target columns are not supported'; return 1;
                }
                ((pos+=1))
                ((pos<close)) || { fail 'empty target column'; return 1; }
            fi
        done
        ((pos+=1))
    elif [[ -n $implicit_columns ]]; then
        parse_ident_list "$implicit_columns" || return
        columns=("${PARSED_COLUMNS[@]}")
    fi
    if ((${#columns[@]}==0)); then
        if ((${#key_specs[@]})) || [[ $match_mode == any ]]; then
            fail 'key/any matching needs column names; supply --columns'; return 1
        fi
        whole_row=1
    fi
    local -a GROUPS_SELECTED=()
    select_keys || return
    if is_word "$pos" OVERRIDING; then
        if is_word "$((pos+1))" USER; then
            fail 'OVERRIDING USER VALUE needs identity-column metadata'; return 1
        fi
        is_word "$((pos+1))" SYSTEM && is_word "$((pos+2))" VALUE || {
            fail 'invalid OVERRIDING clause'; return 1;
        }
        ((pos+=3))
    fi
    source_start=$pos; source_end=$count
    for ((i=pos; i<count; i++)); do
        if ((D[i]==0)) && { is_word "$i" RETURNING || { is_word "$i" ON && is_word "$((i+1))" CONFLICT; }; }; then
            source_end=$i; break
        fi
    done
    if is_word "$pos" DEFAULT; then
        fail 'DEFAULT VALUES requires a table definition'; return 1
    fi
    ((source_start<source_end)) || { fail 'missing INSERT source'; return 1; }

    # Direct VALUES keeps unknown literals in the target column's type context.
    # This is important for dates, UUIDs, enums, and user-defined types.
    if is_word "$pos" VALUES; then
        ((pos+=1))
        while ((pos<source_end)); do
            [[ ${T[pos]} == '(' ]] || { fail 'expected a VALUES row'; return 1; }
            close=${M[pos]}; ((close<source_end)) || { fail 'invalid VALUES row'; return 1; }
            expressions=(); begin=$((pos+1))
            for ((i=begin; i<=close; i++)); do
                if ((i==close)) || { [[ ${T[i]} == ',' ]] && ((D[i]==1)); }; then
                    ((i>begin)) || { fail 'empty VALUES expression'; return 1; }
                    end=${E[i-1]}; start=${S[begin]}
                    expressions+=("${sql:start:end-start}")
                    begin=$((i+1))
                fi
            done
            if ((whole_row)); then
                local row_values=''
                for value in "${expressions[@]}"; do
                    [[ ${value^^} != DEFAULT ]] || {
                        fail 'DEFAULT requires a table definition'; return 1;
                    }
                    [[ -z $row_values ]] || row_values+=', '
                    row_values+=$value
                done
                PREDICATE="ROW(\"__insert2select_target\".*) $comparison_operator ROW((ROW($row_values)::$table).*)"
            else
                ((${#expressions[@]}==${#columns[@]})) || {
                    fail 'VALUES row and target column counts differ'; return 1;
                }
                predicate_kind=values; make_predicate || return
            fi
            rows+=("$PREDICATE"); pos=$((close+1))
            if ((pos<source_end)); then
                [[ ${T[pos]} == ',' ]] || break
                ((pos+=1))
                ((pos<source_end)) || { fail 'missing VALUES row after comma'; return 1; }
            fi
        done
        if ((pos==source_end)); then
            local predicates=''
            for value in "${rows[@]}"; do
                [[ -z $predicates ]] || predicates+=$'\n   OR '
                predicates+=$value
            done
            local table_alias=''
            ((whole_row)) && table_alias=' AS "__insert2select_target"'
            RESULT="${prefix}SELECT * FROM $table$table_alias"$'\nWHERE '"$predicates;"
            return 0
        fi
        # VALUES with ORDER BY/LIMIT/OFFSET is a complete query source.
    elif ! is_word "$pos" SELECT && ! is_word "$pos" WITH && ! is_word "$pos" TABLE && [[ ${T[pos]} != '(' ]]; then
        fail 'expected VALUES or a query source'; return 1
    fi

    # Derived source columns are named by ordinal, independently of SELECT aliases.
    local source aliases='' predicate='' source_alias='"__insert2select_source"' target_alias='"__insert2select_target"'
    begin=${S[source_start]}; end=${E[source_end-1]}; source=${sql:begin:end-begin}
    for ((j=0; j<${#columns[@]}; j++)); do
        [[ -z $aliases ]] || aliases+=', '
        aliases+="\"c$j\""
    done
    local alias_columns=" ($aliases)"
    if ((whole_row)); then
        predicate="ROW($target_alias.*) $comparison_operator ROW(($source_alias::$table).*)"
        alias_columns=''
    else
        predicate_kind=query; make_predicate || return; predicate=$PREDICATE
    fi
    RESULT="${prefix}SELECT $target_alias.* FROM $table AS $target_alias"$'\nWHERE EXISTS (\n  SELECT 1 FROM (\n'"$source"$'\n  ) AS '"$source_alias$alias_columns"$'\n  WHERE '"$predicate"$'\n);'
}
