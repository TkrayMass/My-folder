"""Read configured relay capabilities; never submit a message."""
import json,smtplib
with smtplib.SMTP('ITD-SMTP-OUT.STATE.MA.US',25,timeout=15) as smtp:
    status,_=smtp.ehlo()
    print(json.dumps({'ehlo_status':status,'advertised_size':smtp.esmtp_features.get('size'),
                      'starttls_advertised':'starttls' in smtp.esmtp_features,
                      'message_sent':False},indent=2))
