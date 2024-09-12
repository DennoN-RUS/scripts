#!/bin/sh
# Скрипт для добавляения в /var/hosts записей из зарегистрирвоанных клиентов в кинетике и перезапуск adguard home, если есть изменения в файле
# Нужен для того, что бы в adguard home добавлялись имена клиентво автоматически, без ручной настройки
# Adguard вычитывает файл /etc/hosts из системы, и все записи из этого файла попадают в Клиенты (runtime)
# При этом файл /etc/hosts - это ссылка на файл /var/hosts
# Опрос изменений происходить раз в час
# Перед запуском нужно установить cron командой opkg install cron

# VERSION 1.0.1

#USER VARIABLE
local_iface=br0 #Сюда нужно ввести локальный интерфейс
router_name=S-KN-1811 #Сюда нужно ввести имя роутера (будет отображаться в клиентах в адгуарде)
get_old=1 #тут можно задать 0 или 1, выключает и включает последнюю стадию скрипта, которая сохраняет в файл все устройства, если они были удалены из зарегистрирвоанных клиентов или же пропал ipv6 адрес

#SCRIPT VARIABLE
SYSTEM_PATH="/opt"
FILE_R="$SYSTEM_PATH/etc/host.res" #Тут сохраняются все ip адреса когда-либо замеченные в сети
FILE_O="$SYSTEM_PATH/etc/host.old" #Тут будут появлятся и исчезать устройства, если get_old задано в 1
SCRIPT_PATH="$SYSTEM_PATH/root/scripts" #скрипт должен лежать в папке /opt/root/scripts/
SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")" && SCRIT_FILE="$SCRIPT_PATH/$SCRIPT_NAME"
CRON_FILE="$SYSTEM_PATH/etc/cron.hourly/$SCRIPT_NAME"
RESTART_DNS="$SYSTEM_PATH/etc/init.d/S99adguardhome restart"
USER_SCRIPT="$SYSTEM_PATH/etc/init.d/S04user-scripts"

#SETUP (можно закомментировать после первого запуска)
#Запуск при старте системы
if [ ! -f $USER_SCRIPT ]; then touch $USER_SCRIPT; chmod +x $USER_SCRIPT; fi
if [ $(grep "#!/bin/sh" -c $USER_SCRIPT) -eq 0 ]; then echo "#!/bin/sh" >> $USER_SCRIPT; fi
if [ $(grep "$SCRIT_FILE" -c $USER_SCRIPT) -eq 0 ]; then echo "$SCRIT_FILE" >> $USER_SCRIPT; fi
#Обновление раз в час
if [ ! -s $CRON_FILE ]; then ln -sf $SCRIT_FILE $CRON_FILE; fi

#INIT
create_file(){
  for value in $@; do
    touch $value
  done
}
create_file $FILE_R $FILE_O

check_ip(){
  fIP_LIST="$1"; fNAME="$2"; fMAC="$3"; fFILE="$4"; ret=0
  fDATE=#$(date +%Y.%m.%d-%H:%M:%S)
  for fIP in $fIP_LIST; do
    if [ $(grep -P "$fNAME\t$fIP\t$fMAC" -c $fFILE) -eq 0 ]; then
      if [ $(grep -P "\t$fIP\t" -c $fFILE) -eq 0 ]; then
        echo -e "$fNAME\t$fIP\t$fMAC\t$fDATE"
      else
        sed -i 's/.*\t'$fIP'\t.*/'$fNAME'\t'$fIP'\t'$fMAC'\t'$fDATE'/' $fFILE
      fi
      ret=1
    fi
  done
  return $ret
}

#GET IPS
get_ips(){
  #ADD LOCALHOST AND ROUTER
  fFILE=$2
  check_ip "127.0.0.1 ::1" "localhost" "00:00:00:00:00:00" $fFILE
  ip_list="$(ip addr show dev $local_iface | grep inet | sed 's/\/.*//g' | awk '{print $2}')"
  MAC_r=$(ip -f link addr show dev $local_iface | grep link | awk '{print $2}')
  check_ip "$ip_list" "$router_name" "$MAC_r" "$fFILE"
  #ADD OTHER HOSTS
  i=0
  for item4 in $1; do
    i=$((i+1))
    if [ $((i % 3)) -eq 0 ]; then 
      MAC="$item4"
      i=0
      ip6_list="$(ip -6 neigh show | grep "$MAC" | sort | awk '{print $1}')"
      check_ip "$ip4 $ip6_list" "$NAME" "$MAC" "$fFILE"
    elif [ $((i % 2)) -eq 0 ]; then
      NAME="$item4"
    else 
      ip4="$item4"
    fi
  done
  cat $fFILE
}

#MAKE IP4_LIST variable
IP4_LIST=$(ndmc -c show ip dhcp bindings |
 grep -B5 'expires: infinity' |
 awk '{print $1,$2}' |
 grep -A5 'ip:' | grep -E 'ip|^name|mac' |
 awk '{print $2}' |
 xargs -l3 | sort |
 awk '{print $1,$3,$2}'|
 sed -e 's/_/-/g; s/+//g' -)

get_ips "$IP4_LIST" $FILE_R | sort |
 diff -u $FILE_R - | patch $FILE_R -

#PATCH HOSTS FILE
awk 'BEGIN {OFS="\t"}; {print $2,$1}' $FILE_R | sort |
 diff -u /var/hosts - | patch /var/hosts - |
 if [ $(grep "patching file" -c ) -ne 0 ]; then $(echo $RESTART_DNS); fi

#GENERATE OLD FILE
find_old(){
  ip_list=$(ndmc -c show ip dhcp bindings | grep ip | awk '{print $2}' &&
   ip -6 neigh show | awk '{print $1}' && 
   ip addr show dev $local_iface | grep inet | sed 's/\/.*//g' | awk '{print $2}' &&
   echo "127.0.0.1 ::1")
  CUR_F=$1
  CUR_L=$(awk '{print $2}' $CUR_F)
  OLD_F=$2
  fDATE=#$(date +%Y.%m.%d-%H:%M:%S)
  for fIP in $CUR_L; do
    if [ $(echo $ip_list | grep -E "$fIP( |$)" -c) -eq 0 ]; then
      if [ $(grep -P "\t$fIP\t" -c $OLD_F) -eq 0 ]; then
        grep -P "\t$fIP\t" $CUR_F | awk -v date=$fDATE 'BEGIN {OFS="\t"}; {print $1,$2,$3,date}'
      else
        grep -P "\t$fIP\t" $OLD_F
      fi
    fi
  done
}
if [ $get_old -eq 1 ]; then find_old $FILE_R $FILE_O | sort |
 diff -u $FILE_O - | patch $FILE_O - ; fi
