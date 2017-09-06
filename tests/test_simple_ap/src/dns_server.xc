#include "dns_server.h"
#include "xassert.h"
#include <string.h>

static unsigned short htons(unsigned short x)
{
  return (x >> 8) | (x << 8);
}

static void dns_htons(dns_packet_t & packet)
{
  packet.flags            = htons(packet.flags);
  packet.question_count   = htons(packet.question_count);
  packet.answer_count     = htons(packet.answer_count);
  packet.authority_count  = htons(packet.authority_count);
  packet.additional_count = htons(packet.additional_count);
}

static unsigned int dns_question_length(const dns_question_t & question)
{
  return sizeof(char) + question.name_length + (sizeof(unsigned short) * 2);
}

static dns_question_t dns_question_end()
{
  dns_question_t result = { NULL, 0, DNS_QUESTION_TYPE_UNKNOWN, DNS_QUESTION_CLASS_UNKNOWN, 0xFFFF };
  return result;
}

static void dns_serialize_question(const dns_question_t & question, char * const dst_ptr)
{
  char * const name_ptr = dst_ptr;
  char * const type_ptr = name_ptr + question.name_length + sizeof(char);
  char * const class_ptr = type_ptr + sizeof(short);

  memcpy(name_ptr, question.name, question.name_length);
  memcpy(type_ptr, &question.type, sizeof(short));
  memcpy(class_ptr, &question.class, sizeof(short));
}

static void dns_deserialize_question(const char * const src_ptr, dns_question_t & question)
{
  unsafe {question.name = src_ptr;}
  question.name_length = strlen((const char*)src_ptr);

  const char * const type_ptr = src_ptr + question.name_length + 1;
  const char * const class_ptr = type_ptr + sizeof(short);

  memcpy(&question.type, type_ptr, sizeof(short));
  memcpy(&question.class, class_ptr, sizeof(short));
}

static void dns_serialize_record(const dns_record_t & record, char * const dst_ptr)
{
  char * const name_ptr        = dst_ptr;
  char * const type_ptr        = name_ptr + record.name_length + 1;
  char * const class_ptr       = type_ptr + sizeof(short);
  char * const ttl_ptr         = class_ptr + sizeof(short);
  char * const payload_len_ptr = ttl_ptr + sizeof(int);
  char * const payload_ptr     = payload_len_ptr + sizeof(short);

  memcpy(name_ptr, record.name, record.name_length + 1);
  memcpy(type_ptr, &record.type, sizeof(short));
  memcpy(class_ptr, &record.class, sizeof(short));
  memcpy(ttl_ptr, &record.ttl, sizeof(int));
  memcpy(payload_len_ptr+1, &record.payload_length, sizeof(char));
  memcpy(payload_ptr, record.payload, record.payload_length);
}

static void dns_deserialize_record(const char * const src_ptr, dns_record_t & record)
{
  const char * const name_ptr        = src_ptr;
  const int name_length              = strlen(name_ptr);
  const char * const type_ptr        = name_ptr + name_length + 1;
  const char * const class_ptr       = type_ptr + sizeof(short);
  const char * const ttl_ptr         = class_ptr + sizeof(short);
  const char * const payload_len_ptr = ttl_ptr + sizeof(int);
  const char * const payload_ptr     = payload_len_ptr + sizeof(short);

  unsafe {record.name = name_ptr;}
  record.name_length = name_length;
  memcpy(&record.type, type_ptr, sizeof(short));
  memcpy(&record.class, class_ptr, sizeof(short));
  memcpy(&record.ttl, ttl_ptr, sizeof(int));
  memcpy(&record.payload_length, payload_len_ptr+1, sizeof(char));
  unsafe {record.payload = payload_ptr;}
}

static int dns_question_is_end(const dns_question_t & question)
{
  return NULL == question.name;
}

static dns_question_t dns_question_begin(const dns_packet_t & packet)
{
  dns_question_t result = dns_question_end();

  if (packet.question_count > 0) {
    unsafe {dns_deserialize_question(packet.payload, result);}
    result.index = 0;
  }

  return result;
}

static dns_question_t dns_question_next(const dns_packet_t & packet, const dns_question_t & current)
{
  dns_question_t result = dns_question_end();

  if (current.index + 1 < packet.question_count) {
    unsafe {
      const char * unsafe const ptr = current.name + dns_question_length(current);
      dns_deserialize_question((const void*)ptr, result);
    }
    result.index = current.index + 1;
  }

  return result;
}

static dns_record_t dns_record_end()
{
  dns_record_t result = {NULL, 0, DNS_QUESTION_TYPE_UNKNOWN, DNS_QUESTION_CLASS_UNKNOWN, 0, 0, NULL};

  return result;
}

static int dns_record_is_end(const dns_record_t & record)
{
  return NULL == record.name;
}

static unsigned int dns_questions_length(const dns_packet_t & packet)
{
  unsigned int result = 0;

  for (dns_question_t q = dns_question_begin(packet); !dns_question_is_end(q); q = dns_question_next(packet, q)) {
    result += dns_question_length(q);
  }

  return result;
}

static dns_record_t dns_answer_begin(const dns_packet_t & packet)
{
  dns_record_t result = dns_record_end();

  if (packet.answer_count > 0) {
    const unsigned int questions_length = dns_questions_length(packet);
    const unsigned char * const ptr     = (void*)packet.payload + questions_length;

    dns_deserialize_record(ptr, result);
    result.index = 0;
  }

  return result;
}

static dns_record_t dns_answer_next(const dns_packet_t & packet, const dns_record_t & current)
{
  dns_record_t next = dns_record_end();

  if (current.index + 1 < packet.answer_count) {
    const char * ptr = NULL;
    unsafe {ptr = (const char*)current.payload + current.payload_length;}

    dns_deserialize_record(ptr, next);
    next.index = current.index + 1;
  }

  return next;
}

static unsigned int dns_record_length(const dns_record_t & record)
{
  return 11 + record.name_length + record.payload_length;
}

static unsigned int dns_answers_length(const dns_packet_t & packet)
{
  unsigned int result = 0;

  for (dns_record_t r = dns_answer_begin(packet); !dns_record_is_end(r); r = dns_answer_next(packet, r)) {
    result += dns_record_length(r);
  }

  return result;
}

static unsigned int dns_packet_length(const dns_packet_t & packet)
{
  return 12 + dns_questions_length(packet) + dns_answers_length(packet);
}

static void dns_add_question(const dns_question_t & question, dns_packet_t & packet)
{
  const unsigned int payload_length   = dns_packet_length(packet) - 12;
  unsigned char * const payload_begin = packet.payload;
  unsigned char * const payload_end   = packet.payload + payload_length;

  const unsigned int question_length   = dns_question_length(question);
  unsigned char * const question_begin = packet.payload;
  unsigned char * const question_end   = question_begin + question_length;

  xassert((DNS_MAX_PAYLOAD_SIZE - payload_length) >= question_length);

  memmove(question_end, payload_begin, payload_length);
  unsafe {dns_serialize_question(question, question_begin);}

  packet.question_count++;
}

static void dns_add_answer(const dns_record_t & record, dns_packet_t & packet)
{
  const unsigned int payload_length   = dns_packet_length(packet) - 12;
  unsigned char * const payload_begin = packet.payload;
  unsigned char * const payload_end   = packet.payload + payload_length;

  const unsigned int questions_length   = dns_questions_length(packet);
  unsigned char * const questions_begin = payload_begin;
  unsigned char * const questions_end   = questions_begin + questions_length;

  const unsigned int record_length   = dns_record_length(record);
  unsigned char * const record_begin = questions_end;
  unsigned char * const record_end   = record_begin + record_length;

  xassert((DNS_MAX_PAYLOAD_SIZE - payload_length) >= record_length);

  memmove(record_end, questions_end, payload_end - questions_end);
  dns_serialize_record(record, record_begin);

  packet.answer_count++;
}

static void dns_handle_question(const dns_packet_t & packet_in, const dns_question_t & current, dns_packet_t & packet_out)
{
  const char name[] = "\3vda\5setup";
  xtcp_ipaddr_t address = {192, 168,   0,   1};
  dns_record_t record;
  unsafe {record.name = name;}
  record.name_length = strlen(name);
  record.type = 0x0100;
  record.class = 0x0100;
  record.ttl = 0xFFFFFFFF;
  record.payload_length = sizeof(xtcp_ipaddr_t);
  unsafe {record.payload = (void*)&address;}

  if (current.name_length == 10 && memcmp(current.name, name, 10) == 0) {
    packet_out.flags = 0x8000;

    dns_add_answer(record, packet_out);
  } else {
    packet_out.flags = 0x8385;
  }
}

static void dns_handle(client xtcp_if i_xtcp, xtcp_connection_t & conn, dns_packet_t & packet)
{
  dns_htons(packet);
  dns_packet_t packet_out = {packet.id, 0, 0, 0, 0, 0};

  for (dns_question_t q = dns_question_begin(packet); !dns_question_is_end(q); q = dns_question_next(packet, q)) {
    dns_add_question(q, packet_out);
    dns_handle_question(packet, q, packet_out);
  }

  const unsigned int packet_out_length = dns_packet_length(packet_out);
  dns_htons(packet_out);
  const int result = i_xtcp.send(conn, (void*)&packet_out, packet_out_length);
}

void dns_server(client xtcp_if i_xtcp)
{
  xtcp_connection_t conn = i_xtcp.socket(XTCP_PROTOCOL_UDP);
  i_xtcp.listen(conn, 53, XTCP_PROTOCOL_UDP);

  while(1) {
    select {
      case i_xtcp.event_ready():
        xtcp_connection_t conn_tmp;

        switch(i_xtcp.get_event(conn_tmp)) {
          case XTCP_RECV_DATA:
            unsafe {
              dns_packet_t packet;
              const int result = i_xtcp.recv(conn_tmp, (void*)&packet, sizeof(packet));
              if (result > 0) {
                dns_handle(i_xtcp, conn_tmp, packet);
                i_xtcp.close(conn_tmp);
              }
            }
            break;
        }
        break;
    }
  }
}