# PostgreSQL lexical boundaries only; PostgreSQL remains the SQL parser.
# sql_split populates SQL_STATEMENTS. Requires standard_conforming_strings=on.
sql_split() {
    local sql=$1 i=0 start=0 n=${#1} c next state=normal tag='' level=0
    local escaped=0 has_code=0 word='' statement
    SQL_STATEMENTS=()
    while (( i < n )); do
        c=${sql:i:1} next=${sql:i+1:1}
        case $state in
            line)
                [[ $c == $'\n' ]] && state=normal
                ;;
            comment)
                if [[ $c$next == '/*' ]]; then
                    ((level+=1, i+=1))
                elif [[ $c$next == '*/' ]]; then
                    ((level-=1, i+=1))
                    ((level == 0)) && state=normal
                fi
                ;;
            single)
                if [[ $c == "'" ]]; then
                    if [[ $next == "'" ]]; then ((i+=1)); else state=normal; fi
                elif ((escaped)) && [[ $c == \\ ]]; then
                    ((i+=1))
                fi
                ;;
            double)
                if [[ $c == '"' ]]; then
                    if [[ $next == '"' ]]; then ((i+=1)); else state=normal; fi
                fi
                ;;
            dollar)
                if [[ ${sql:i:${#tag}} == "$tag" ]]; then
                    ((i+=${#tag}-1))
                    state=normal
                fi
                ;;
            normal)
                if [[ $c$next == '--' ]]; then
                    state=line; word=''; ((i+=1))
                elif [[ $c$next == '/*' ]]; then
                    state=comment; level=1; word=''; ((i+=1))
                elif [[ $c == "'" ]]; then
                    state=single; has_code=1; escaped=0
                    [[ $word == E || $word == e ]] && escaped=1
                    word=''
                elif [[ $c == '"' ]]; then
                    state=double; has_code=1; word=''
                elif [[ $c == '$' && -z $word ]] &&
                     [[ ${sql:i} =~ ^(\$([[:alpha:]_][[:alnum:]_]*)?\$) ]]; then
                    tag=${BASH_REMATCH[1]}; state=dollar; has_code=1
                    ((i+=${#tag}-1))
                elif [[ $c == ';' ]]; then
                    if ((has_code)); then
                        statement=${sql:start:i-start}
                        SQL_STATEMENTS+=("$statement")
                    fi
                    start=$((i+1)); has_code=0; word=''
                elif [[ $c == \\ ]]; then
                    printf '%s: psql commands are not SQL input (offset %s)\n' "${program_name:-insert2select}" "$i" >&2
                    return 1
                elif [[ $c == [[:alnum:]_\$] ]]; then
                    word+=$c; has_code=1
                elif [[ $c == [[:space:]] ]]; then
                    word=''
                else
                    word=''; has_code=1
                fi
                ;;
        esac
        ((i+=1))
    done
    case $state in
        normal|line) ;;
        *) printf '%s: unterminated SQL %s\n' "${program_name:-insert2select}" "$state" >&2; return 1 ;;
    esac
    if ((has_code)); then SQL_STATEMENTS+=("${sql:start}"); fi
    return 0
}
