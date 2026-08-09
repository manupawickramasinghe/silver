import time
import timeit
import imaplib

class MockIMAP:
    def __init__(self):
        self.latency = 0.05 # 50ms simulated network latency

    def fetch(self, msg_id, parts):
        time.sleep(self.latency)

        # Simulate imaplib fetch response structure
        msg_ids = msg_id.split(b',')

        response_data = []
        for mid in msg_ids:
            # imaplib typically returns a tuple for the data part and the closing parenthesis
            response_data.append((f"{mid.decode()} (RFC822 {{10}}".encode(), b"fake body\n"))

        return 'OK', response_data

def baseline():
    mail = MockIMAP()
    recent_ids = [b'1', b'2', b'3', b'4', b'5']

    fetched_count = 0
    for msg_id in recent_ids:
        status, msg_data = mail.fetch(msg_id, '(RFC822)')
        if status == 'OK':
            fetched_count += 1
    return fetched_count

def optimized():
    mail = MockIMAP()
    recent_ids = [b'1', b'2', b'3', b'4', b'5']

    msg_sequence = b','.join(recent_ids)
    status, msg_data = mail.fetch(msg_sequence, '(RFC822)')

    fetched_count = 0
    if status == 'OK':
        # imaplib fetch response structure usually has one tuple per message part,
        # plus possibly other elements. Let's assume one message per tuple.
        fetched_count = len([d for d in msg_data if isinstance(d, tuple)])
    return fetched_count

print(f"Baseline: {timeit.timeit(baseline, number=10)} seconds")
print(f"Optimized: {timeit.timeit(optimized, number=10)} seconds")
