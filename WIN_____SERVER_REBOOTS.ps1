add-pssnapin mvpsi.jams
#
# This will examine the parameters passed, and will attempt to reboot
# the list of servers, in the order provided, optionally stopping
# services, optionally disabling tasks
#
#  On all servers:  the order of executions is:
#
#  The general rule is:
#   1.	in REVERSE ORDER of the servers;
#       a.	disable any tasks
#       b.	stop any services
#   2.	In SERVER ORDER:
#       a.	REBOOT and wait for the server reboot to complete
#            optionally - run a JAMS job waiting for it to complete
#            optionally - wait for a service to reach a desired state
#       b.	when the server is back up;
#           i.	start the service(s) associated with this  server if needed
#           ii.	enable the task(s) associated with this server
#
# format that is expected for each line of the parameters passed is:
#
#
#
$VER="2.0"
# 1/26/2015 hsamm  - added logic on reboot, to wait until the 'systeminfo' command comes back with the
#                   string " Time:" before it assumes that windows is up and functional.

#  SERVERNAME|servicename1,servicename2,service3,...|taskname1,taskname2,...:service=name=state
#                  or
#  sleepnnn::   - a number of seconds to sleep before proceeding
#                  or
#  job::UNC_jobname   -  name of a job to run and wait for completion before proceeding
#                  
#  
#
#
$VER="2.1"  # 2/3/2015 - hsamm - made it so that servers entered in the parameter list are entered in 
#                                order that the reboots are to occur.
$VER="2.2"  # 2/4/2015 - hsamm - placed in a pre-check list to insure that we're at least able to communicate
#                                with the server.  also on a trial run, don't end, just continue on, but not
#                                potential problems for diagnostic purposes.
$VER="3.0"  # 2/4/2015 - hsamm - logic to handle a 4th parameter - format is:
#                                  service=servicename=running
#                                what this will do is once server has come back up from a reboot, the
#                                reboot process will wait until the service referenced by name is in the
#                                state.  useful in cases where a DB server has been rebooted and a wait is 
#                                needed until the SQL agent is running.
#
$VER="3.1"  # 2/6/2015 - hsamm - added a query for the field service=name=state for the trial balance
#                                just showing what the current state the service is in.
#
$VER="3.2"  # 2/9/2015 - hsamm - added logic to allow multiple service=name=state
#
$VER="4.0"  # 2/10/2015 - hsamm - add logic for ASYNC reboots of servers - with servers marked as
#                                 ASYNC, a separate JAMS job will be started.  A variable will be
#                                 set in 00_SAMC_GLOBAL_VARIABLES with the name REB00T_nnnn where
#                                 nnnn is the JAMS entry number.  the "child" job will read that
#                                 variable, which will be nothing more than the name of the server
#                                 that needs to be rebooted, and it will do nothing more than perform
#                                 ONLY the same REBOOT section of this job, without any contingencies.
#
#
$VER="4.1"  # 2/11/2015 - hsamm - logic to remove extraneous spaces around commas and colons
$VER="4.1.1" # 2/12/2015 - hsamm - logic to treat and ignore any parameter that starts with a
#                                   pound sign (comment)
$VER="4.2" # 2/12/2015 - hsamm - logic to capture the log from any JAMS job that is executed
#                                and display it in this job log


function fire_up_ASYNC
{
   param($server)
#
# ok, so, submit the REBOOT_ASYNC job, but keep it on hold until I create it's variable.
#  the variable will be created using the JAMS entry number of the actual job itself
#  as part of the variable name  the variable name will be:  ASYNC_nnnn where nnnn is
#  the jams entry number.
#
   
   

   $subjob = Submit-JAMSEntry \SAMC_specalized_jobs\SERVER_REBOOTS\REBOOT_ASYNC -Hold

   $VARNAME="ASYNC_" +$subjob.JAMSEntry
   TS; write-host "JAMSEntry is: " $VARNAME
   TS; write-host "   for server: " $server

   # this is where I will create the variable.

   CD JAMS::localhost\SAMC_specalized_jobs\SERVER_REBOOTS\TEMP


   $MyVar = New-item -name $VARNAME -ItemType Variable
   $MyVar.Description = "ASYNC REBOOT for $server"
   $MyVar.Value = "$SHOWONLY $server"
   $MyVar.DataType = [MVPSI.JAMS.DataType]::Text
   $MyVar.CurrentLength = 50
   $MyVar.Update()
   
   # now that the variable has been created, go ahead and release the job
   #  that is currently on hold
   
   Resume-JAMSEntry -name $subjob.JAMSEntry

}

function TS
{
   $TIMS=get-date -format "HH:mm:ss"
   write-host -nonewline "$TIMS - "
}


function reboot_the_server
{  
   param($machine_name)

   # Set-PSdebug -trace 2
  TS; write-host "Performing actual reboot of server: $machine_name"
   $machine = Get-WMIObject win32_operatingsystem -computer $machine_name
   $machine.Reboot() | foreach {
      TS; write-host "     $_"
   }
   #
   #  Wait until the machine is gone 
   #
   $ping = new-object System.Net.Networkinformation.Ping
   do
   {
     TS; write-host "Going - waiting for $machine_name to stop answering pings"
     Start-Sleep -s 2
	   $result = $ping.send($machine_name);
   } Until($result.status -ne "Success")
   TS; write-host "Gone $machine_name no longer answering pings"
   #
   #  Wait until the machine comes back
   #
   do
   {
	   $result = $ping.send($machine_name);
     TS; write-host "Waiting for server $machine_name to answer pings"
     Start-Sleep -s 10
   } Until($result.status -eq "Success")
   TS; write-host "$machine_name is now answering pings"
   TS; write-host "will now wait until server responds to the systeminfo command"
   $RSVP1=""
   do
   {
      TS; write-host "performing systeminfo command"
      $command="systeminfo /s $machine_name "
      $RSVP1=" "
      TS; write-host "Waiting for server to respond to systeminfo command"
      Invoke-Expression $command | ForEach-Object{
        

         if($_.Contains(" Time:")){
             $RSVP1="Success"
             TS; write-host "systeminfo: Success"
             
         }
      }
      start-sleep -s 10
   }until ($RSVP1 -eq "Success")
  

   set-PSdebug -trace 0
   
}


function control_a_service
{
     param($server_name,$service_name,$what_to_do)
     TS; write-host "On server: $server_name, service: $service_name, will be: $what_to_do"


     #Initialize variables:
     [string]$WaitForIt = ""
     [string]$Verb = ""
     [string]$Result = "FAILED"

     $svc = (get-service -computername $server_name -name $service_name -ErrorAction SilentlyContinue -ErrorVariable NoService)
     if($NoService){
        TS; WARN "A problem was encountered processing service: $service_name on: $server_name" $NoService
        return
     }

     TS; Write-host "Current state is: $SvcName on $SvrName is $($svc.status)"

     Switch ($what_to_do){
          'stop'{
                TS; write-host "Stopping service: $service_name"
                $Verb="stop"
                $WaitForIt = 'Stopped'
                $svc.Stop()
                }
          'start'{
                 TS; write-host "Starting service: $service_name"
                 $Verb="start"
                 $WaitForIt = 'Running'
                 if($svc.status -ne "Running"){
                    $svc.Start()
                    }else{
                       TS; write-host "Service is alredy running, no need to start it"
                    }
                 }
          'query' { $Result = 'SUCCESS'; return }
     }
     

     if ($WaitForIt -ne "") {
         Try {  # For some reason, we cannot use -ErrorAction after the next statement:
             $svc.WaitForStatus($WaitForIt,'00:02:00')
         } Catch {
             TS; Write-host "After waiting for 2 minutes, $service_name failed to $Verb."
             throw "service failed to start"
         }

         $svc = (get-service -computername $server_name -name $service_name)
         if ($svc.status -eq $WaitForIt) {$Result = 'SUCCESS'}
         TS; Write-host "$Result`: $service_name on $server_name is $($svc.status)"
     }
}

#
# control_schduled_task
#
#    passed to function: servername, taskname, what_to_do
#      NOTE:  because ONLY the taskname is passed, I need to get the entire path of the task
#             otherwise any schtasks actions will fail.  Taskname is coming to me as quoted because it
#             may contain spaces...so... handle that too
function control_scheduled_task
{
  param($ComputerName,$TaskName,$WhatToDo)
  # set-PSdebug -trace 2

  TS; write-host "<<< processing: $WhatToDo on: $ComputerName TaskName: $TaskName >>>"

  $command="schtasks.exe /query /s $ComputerName /fo csv /nh"
  $TASKLIST=Invoke-Expression $command
  
  $TaskName=$TaskName.Replace('"','')
  
  #
  # so, the TASKLIST contains all tasks that are on the host, now go thru it, match up
  # the one they are looking for, and then act upon it using the full path
  
  foreach ($tsk in $TASKLIST){
      if($tsk.Contains("\$TaskName")){
         $wa = $tsk.split(",")
         TS; write-host ("     Found: "+$wa[0])
         $TaskName=$wa[0]
         $TaskName | foreach{
            TS; write-host "          $_"
         }
      }
  }


  Switch ($WhatToDo){
     'end' {
              $command="schtasks.exe /query /s $ComputerName /tn $TaskName"
              $RSVP=Invoke-Expression $command
           }
     'disable' {
                 $command="schtasks.exe /change  /s $ComputerName /tn $TaskName /DISABLE"
                 $RSVP=Invoke-Expression $command
               }
     'enable' {
                 $command="schtasks.exe /change /s $ComputerName /tn $TaskName /ENABLE"
                 $RSVP=Invoke-Expression $command
              }
     'query' {
                $command="schtasks.exe /query /s $ComputerName /tn $TaskName"
                $RSVP=Invoke-Expression $command
             }
     default {
                return "ERROR, unknown WhatToDo: $WhatToDo"
             }
  
  }
  
  
  set-PSdebug -trace 0
  return "$RSVP"
  
  
  

	
}

function WARN
{ 
   param ($message, $diags)
   TS; write-host "WARNING WARNING WARNING"
   TS; write-host "WARNING WARNING WARNING --- $message"
   TS; write-host "WARNING WARNING WARNING"
   TS; write-host "====================  Diagnostics follows:============================================"
   $diags
   write-host "======================================================================================"
   if($Global:SHOWONLY -eq "y"){
      $Global:THROWUP=1
   }else{
      TS; write-host "THIS IS AN ACTUAL RUN, THE PARAMETER WILL BE IGNORED"
      $Global:THROWUP=1
   }

}

function wait_for_it
{
   param ($server, $what2wait4)
   TS; write-host ""
   TS; write-host "===> On server: $server, Performing Wait For: $what2wait4"
   TS; write-host ""
   $xdx=1

   $what2wait4.split("=") | foreach{
     
     $wa=$_
     
     switch($xdx){
        1 { $what = $wa }
        2 { $what_name = $wa }
        3 { $what_state = $wa }
        default { write-host "This should never happen" }
     }
     $xdx++
   }
   switch ($what){
      "service" { 
                   $im_done=0
                   do{
                        $svc = get-service -computername $server -name $what_name -ErrorAction SilentlyContinue -ErrorVariable NoService
                        if($NoService){
                           WARN "Service not found on host" " " 
                        }
                        TS; write-host "svc.status for $what_name is: " $svc.status
                        if($svc.status -eq $what_state){
                             $im_done = 1
                             TS; write-host " 			$what2wait4 has been met"
                        }else{
                           TS; write-host "waiting for $what_name to become $what_state"
                           start-sleep -s 60
                        }
                     }until ($im_done -eq 1)
                }
      default {
                WARN "Unable to determing: $what2wait4"
              }
   }
   

}






#
#  call the fucntion    reboot_the_server -machine_name $variable
#
$Global:SHOWONLY="<<TRIAL_RUN>>"
TS; write-host ""
TS; write-host "JAMS SERVER REBOOT - version $VER"
TS; write-host ""

$GLOBAL:THROWUP=0      # used for tial run, if any errors occur, set this switch to 1, but continue on processing.

if($SHOWONLY -eq "y"){
   
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host ""
   TS; write-host "  NO ACTUAL REBOOT WILL OCCUR, SHOW_ONLY SET TO 'Y'"
   TS; write-host ""
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
   TS; write-host "TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN     TRIAL RUN"
}else{
   
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host ""
   TS; write-host "  WARNING:  REBOOTING of the servers will actuall be performed"
   TS; write-host ""
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
   TS; write-host "REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT     REBOOT"
}

$SI="<<SERVER_INFO>>"
$SIW=@()

$SI=$SI.split("`r`n") | where-object {$_.trim() -ne ""}

#
# do syntext checking
#
# OK, so we're gonna make some assumptions here....
#  If there are no colons, assume it's just a servername only, I'll add 3 colons
#  If there is only 1 colon, I'll add 2 colons
#  If there is only 2 colons, I"ll add 1 colon
#
 

foreach ($i in $SI){
   

   switch($i.split(":").Count){
   0 {
        TS; write-host "This should never happen for '$i'"
     }
   1 {
        $SIW+="$i" +':::'
     }
   2 {
        $SIW+="$i" +'::'
     }
   3 {
        $SIW+="$i" +':'
     }
   4 {
        $SIW+="$i"
     }
   }
}


# strip out and " ,"  or " , " or ", " in the lines
#
$SIWW=@()
$SIW | foreach{
   $wa=$_
   $wa1=$wa.replace(" , ",",")
   $wa2=$wa1.replace(" ,",",")
   $wa3=$wa2.replace(", ",",")
   $wa4=$wa3.replace(" : ",":")
   $wa5=$wa4.replace(" :",":")
   $wa6=$wa5.replace(": ",":")
   if(!$wa6.StartsWith("#")){        # ignore this line if it is a comment
      $SIWW+=$wa6
   }
}
$SIW=$SIWW

TS; write-host "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< PARAMETERS >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
$SIW | foreach{
   TS; write-host "$_"
}
TS; write-host "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< PARAMETERS END >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"



#
# now, first, do the ASYNC servers, don't pass them any further into the script
# set-psdebug -trace 2
TS; write-host "============================================================================================"
TS; write-host " doing ASYNC servers first"
TS; write-host "============================================================================================"
$WIS=$SIW
$SIW=@()   # reset SIW to empty

$WIS | foreach{
   $sn = $_
   if($sn.contains("ASYNC")){  # these will be handled by the async reboot process
      $wa=$sn.split(":")
      TS; write-host " peforming ASYNC for server: " ($wa[0])
      fire_up_ASYNC ($wa[0])
   }else{
      $SIW+=$sn  # these will be passed on to the rest of the script.
   }
   
}



$SI=$SIW
$SIR=$SI
[array]::Reverse($SIR)


####  now, get the services and tasks per server that need to be addressed

$SERVER=@()
$SERVICES=@{}
$SeRvIcEs1=@{}
$ServerServices=@()
$TASKS=@{}
$ServerTasks=@()
$tasks1=@{}
$WaitFor=@{}

$THROWUP=0
TS; write-host "=============================================================================="
TS; write-host "<<<<< pre-check list - see what state server is in >>>>>"
TS; write-host "=============================================================================="

foreach ($serverline in $SIR){
   $WA=$serverline.split(":")
   $x=0
   foreach ($field in $WA){
     
      
      switch($x){
         0 {
               # before even adding in the server, see if we're even able to communicate with it..
               # if not, then don't even bother putting it in the table
               if( ($field.contains("sleep")) -Or ($field.contains("job")) ){
                  $servername=$field
                  $SERVER+=$field
               }else{
                 $machine = Get-WMIObject win32_operatingsystem -computer $field -ErrorAction SilentlyContinue -ErrorVariable NoWMI
                 if($NoWMI){
                   WARN "on server: $field Get-WMIObject failed or JAMS has a permissions problem" $NoWMI
                   $servername="null" # this will just create a placeholder for anything that follows
                 }else{
                    $servername=$field
                    $SERVER+=$field
                 }
               }
           }
         1 {$SERVICES.Add($servername,$field)
            $ServerServices=@()
            $field.split(",") | ForEach-Object{
               $ServerServices+=$_
            }
            $SeRvIcEs1.$servername=($ServerServices)
           
            
           }
         2 {$TASKS.Add($servername,$field)
            $ServerTasks=@()
            $field.split(",") | ForEach-Object{
               $ServerTasks+=$_
            }
            $tasks1.$servername=($ServerTasks)
           }
         3 {
             $WaitFor.$servername=($field)
           }
      }
      $x++
   }
}





TS; write-host "=============================================================================="
TS; write-host "<<<<< STEP ONE - stop and  disable TASKS in this order >>>>>"
TS; write-host "=============================================================================="

foreach ($sn in $SERVER){
     if(!$sn.contains("job")){
     
        
     TS; write-host ""
     if( ($TASKS.item($sn) -ne "") -And ($sn -notcontains "sleep")){
        TS; write-host "  on $sn, disable task" $TASKS.item($sn)
        # get status of task, just to insue that it does exist
        $TASKS.item($sn).split(",") | foreach{
           $response = control_scheduled_task $sn "`"$_`"" query
           if( ($response.contains("Ready")) -OR ($response.contains("Running")) ){
              TS; write-host "   OK, task is on remote server, and in 'Ready or Running' state"
           }else{
              TS; write-host "   WARNING, either task is not on server, or not in 'Ready or Running' state" 
              TS; write-host "   host reponse is:"
              $response | foreach{
                 TS; write-host "$_"
              }
              WARN "Some Tasks were not found on the server" " "
           }
           # if showonly set to no, then perform the actual ending and disabling of the task
           if($SHOWONLY -eq "N"){
               $response = control_scheduled_task $sn "$_" "end"
               $response = control_scheduled_task $sn "$_" "disable"
               if($response.contains("SUCCESS")){
                  TS; write-host "      SUCCESS - task was ended and disabled"
               }else{
                  TS; write-host "      FAILURE - task did not disable"
                  TS; write-host "      the following is the response:"
                  $response | foreach {
                     TS; write-host "$_"
                  }
               }
           }
        }
        
          
        
        
           
    
     }
  }
}


TS; write-host "=============================================================================="
TS; write-host "<<<<< STEP TWO - disable SERVICES in this order >>>>>"
TS; write-host "=============================================================================="
foreach ($sn in $SERVER){
   if(!$sn.contains("job")){
     TS; write-host ""
     if( ($SERVICES.item($sn) -ne "") -And ($sn -notcontains "sleep")){
        TS; write-host "  on $sn, disable service " $SERVICES.item($sn)
        $SERVICES.item($sn).Split(",") | foreach{
           TS; write-host "		 command: sc \\$sn stop $_"
           # get status just to insue that the service does exist
           $svc = (get-service -computername $sn -name $_ -ErrorAction SilentlyContinue -ErrorVariable NoService)
           if($NoService){
             WARN "A problem occurred when querying the service" $NoService
           }
           TS; write-host "			Serice status: " $($svc.Status)
         
           if($SHOWONLY -eq "N"){
              if(($svc.Status) -eq "Stopped"){
                   TS; write-host "			WARNING: service is already stopped"
              } else {
                   control_a_service $sn $_ "stop"
              }
           }
        }
     }
  }
}

TS; write-host "=============================================================================="
TS; write-host "<<<<< STEP THREE - reboot servers in this order in this order >>>>>"
TS; write-host "=============================================================================="

$RSERVER=$SERVER
[array]::Reverse($RSERVER)




foreach ($sn in $RSERVER){
     TS; write-host ""
     if($sn.contains("sleep")){
         $seconds=$sn.replace("sleep","")
         TS; write-host "Number of seconds to SLEEP before proceeding " $seconds
         if($SHOWONLY -eq "N"){
            TS; write-host "			Sleeping for $seconds seconds"
            Start-Sleep -s $seconds
            TS; write-host "			Done sleeping"
         }
     }elseif(!$sn.contains("job")){
    
         TS; write-host "$sn"

         TS; write-host "		command: reboot_the_server $sn"
         # do the following just to insure that the actual server does exist
         $machine = Get-WMIObject win32_operatingsystem -computer $sn
         TS;write-host "			$sn status: " $($machine.Status)
         #  if there is a waitfor, display it here, and if for real, then do what
         #  waitfor says to do.
         if($WaitFor.item($sn) -ne ""){
            TS; write-host "		*** wait_for_it $sn " $WaitFor.item($sn)
            # there may be multiple entries, so, split and process each of them
            $WaitFor.item($sn).split(",") | foreach{
               $XXYYZZ=$_
               TS; write-host "XXYYZZ: $XXYYZZ"
               # get the service name
               $x=0
               $xservice="NULL"
               $XXYYZZ.split("=") | foreach{
                  $wa=$_
                  $x++
                  switch($x){
                    2 {$xservice = $wa}
                  }
               }
               TS; write-host "passing: $sn $xservice 'query'"
               control_a_service $sn $xservice "query"
             }
         }
         if($SHOWONLY -eq "N"){
            reboot_the_server $sn
            if($WaitFor.item($sn) -ne ""){
               $WaitFor.item($sn).split(",") | foreach{
                  wait_for_it $sn $_
                }
            }
         }
     }
     if($sn.contains("job")){
        $JAMSJOB=$TASKS.item($sn)
        TS; write-host "JOB to be executed and wait for completion: $JAMSJOB"
        if(Test-Path JAMS::pintjams2\$JAMSJOB){
           TS; write-host "SUCCESS: job was found"
           if($SHOWONLY -eq "N"){
              TS; write-host "submitting the job, and waiting for completion"
              $jresults=submit-JAMSEntry -Name $JAMSJOB
              wait-JAMSEntry $jresults.JAMSEntry
              TS; write-host "Job has completed, continue on JAMSEntry: " $jresults.JAMSEntry
              # get the log file from the job that completed, and log it to this log
              $jamsxEntry=get-JAMSEntry -Entry $jresults.JAMSEntry
              $LOGFILENAME=$jamsxEntry.LogFileName
              TS; write-host "LOG: " $LOGFILENAME
              get-content $LOGFILENAME.ToString() | foreach{
                 TS; write-host "joblog=>" $_
              }
              
              
           }
        }else{
           WARN "JOB: $JOBNAME - was not found in JAMS" " "
        }
     }
}

TS; write-host ""
TS; write-host "=============================================================================="
TS; write-host "<<<<< STEP FOUR - insure the services are up and running in this order >>>>>"
TS; write-host "=============================================================================="
$RSERVICES=$SERVICES
[array]::Reverse($RSERVICES)
foreach ($sn in $RSERVER){
  if(!$sn.contains("job")){
     TS; write-host ""
     if(($RSERVICES.item($sn) -ne "") -And ($sn -notcontains "sleep")){
        TS; write-host "  on $sn, insure service(s) are running:" $RSERVICES.item($sn)
           $RSERVICES.item($sn).Split(",") | foreach{
              TS; write-host "   command control_a_service $_ start"
              control_a_service $sn $_
              if($SHOWONLY -eq "N"){
                 control_a_service $sn $_ "start"
              }
           }
        
     }
  }
}

TS; write-host ""
TS; write-host "=============================================================================="
TS; write-host "<<<<< STEP FIVE - insure the tasks are enabled in this order >>>>>"
TS; write-host "=============================================================================="
$RTASKS=$TASKS
[array]::Reverse($RTASKS)
foreach ($sn in $RSERVER){
  if(!$sn.contains("job")){
     TS; write-host ""
     if(($RTASKS.item($sn) -ne "") -And ($sn -notcontains "sleep")){
        TS; write-host "  on $sn, insure task(s) are enabled:" $RTASKS.item($sn)
        $RTASKS.item($sn).split(",") | foreach{
           control_scheduled_task $sn "$_" "query" | foreach{
#
#          here, if the line to be display is longer than 60 chars, split it up so that it is
#          easier to read
#
              if($_.length -lt 60){
                   TS; write-host "          $_"
              }else{
                 $xyz=$_.split(" ")
                 $zyxlen=0
                 TS
                 foreach ($zyx in $xyz){
                    $zyxlen=$zyxlen + $zyx.length
                    if($zyxlen -gt 60){
                       write-host ""
                       $zyxlen=0
                       TS
                       write-host -nonewline "$zyx "
                    }else{
                       write-host -nonewline "$zyx "
                    }
                 }
                 write-host ""
              }
           }
           if($SHOWONLY -eq "N"){
              $response = control_scheduled_task $sn "$_" "enable"
              if($response.contains("SUCCESS")){
                 TS; write-host "          SUCCESS - task was enabled"
              }else{
                 WARN "A problem was encountered trying to enable a task" " "
                 $response | foreach {
                    TS; write-host "$_"
                 }
              }
           }
        }
      
     }
  }
}

if( ($GLOBAL:THROWUP -eq 1) -And ($SHOWONLY -eq "Y") ){
   TS; write-host "The trial run has errors.  If not corrected, they will be skipped / ignored"
   TS; write-host "for an actual run"
   throw "TRIAL RUN HAS ERRORS"
}

if($GLOBAL:THROWUP -eq 1){
   throw "ACTUAL RUN completed with ERRORS"
}

